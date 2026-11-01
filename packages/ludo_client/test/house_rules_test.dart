// Proof for C-356's acceptance (work/ludo/orders/C-356-house-rules-client.md,
// the 10-15 rule ruling, X55/X57), written from that contract directly,
// against no implementation of order 356's work: on this branch
// lib/src/home_screen.dart still carries a Blocks switch (home-rule-blocks),
// lib/src/lobby_screen.dart still carries a Blocks chip (lobby-rule-blocks,
// lobby-rule-blocks-chip), RoomToggles (net/connection.dart) still has a
// blocks field, and there is no houseRulesLine l10n getter anywhere, so this
// file cannot compile until order 356 lands. The getter's absence is itself
// part of what run against base must show (see the acceptance-run note
// below).
//
// Amended for C-523 (D1, D6, D9): groups 2 and 3 (the house-rules line and the
// capture-bonus hint) and the host-turns-capture-bonus-off case of group 4
// went with houseRulesLine, HomeRuleToggle and the lobby line. What remains:
//   1. no widget with any of the removed keys (home-rule-blocks,
//      lobby-rule-blocks, lobby-rule-blocks-chip) exists on home, or in the
//      lobby, host or guest;
//   4. RoomToggles().toJson() == {'capture_bonus': true};
//   5. at text scale 2.0 on 360x640 the lobby still passes C-347's own
//      large-text claim (seat names whole, no FlutterError), and
//      lobby-house-rules is no longer on screen.
//
// Mounting follows test/lobby_seat_cards_test.dart (a real RoomController
// over a FakeTransport, never a mock) for the lobby, and
// test/home_rule_toggles_test.dart for home (a fresh FakeTransport per
// connect, through an injected controllerFactory). Every helper below is
// copied from those two files' own idiom (and, for group 5, from
// test/large_text_lobby_names_test.dart's font-loading and surface helpers)
// rather than imported: none of it is exported by those files, and none of
// them is on this order's file list to modify. One mount per case
// throughout; no pumpAndSettle once a LobbyScreen or a pushed route is on
// screen, per this repository's own standing lesson.
//
// Literal strings quoted directly from the contract, never looked up through
// AppLocalizations, for groups 2 and 3 (the acceptance text says so
// explicitly for group 2; group 3 follows the same discipline since it is
// proving the exact same kind of wording change).

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/connection.dart' show RoomToggles;
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/server_config.dart';
import 'package:ludo_client/src/theme.dart' show buildAppTheme;

import 'net/fake_transport.dart';

const String _testUrl = 'wss://house-rules-test.invalid/ws';

const Key _blocksSwitchKey = Key('home-rule-blocks');
const Key _lobbyHouseRulesKey = Key('lobby-house-rules');
const Key _lobbyRuleBlocksKey = Key('lobby-rule-blocks');
const Key _lobbyRuleBlocksChipKey = Key('lobby-rule-blocks-chip');
// ---------------------------------------------------------------------------
// Small JSON helpers, copied from test/lobby_start_with_present_test.dart.
// ---------------------------------------------------------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'house-rules-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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

Map<String, Object?> _seatJson(
  int seat, {
  String name = '',
  bool connected = true,
}) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': connected,
  'tokens': <int>[-1, -1, -1, -1],
  'client_seed': null,
  'seed_origin': null,
};

/// The server's own wire shape for `rules` (net/snapshot.dart still parses
/// `blocks`, because servers still send it -- decision 3). Not a client-side
/// toggle; left exactly as every other file in this suite leaves it.
Map<String, Object?> _roomJson({
  String code = 'ABC234',
  String state = 'LOBBY',
  int hostSeat = 0,
  int players = 2,
  List<Map<String, Object?>>? seats,
  int seq = 1,
}) => <String, Object?>{
  'code': code,
  'state': state,
  'host_seat': hostSeat,
  'players': players,
  'rules': <String, Object?>{
    'blocks': false,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': null,
  'client_seeds': null,
  'seats':
      seats ??
      <Map<String, Object?>>[_seatJson(hostSeat, name: 'Sam', connected: true)],
  'turn': null,
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

RoomController _newController(_Connector connector) =>
    RoomController(serverUrl: Uri.parse(_testUrl), connect: connector.call);

Widget _lobbyHarness(Widget child, {required Locale locale}) {
  return MaterialApp(
    theme: buildAppTheme(),
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

/// Mounts a connected 2-seat LobbyScreen as [mySeat] (host when [mySeat] ==
/// 0, otherwise a guest joining room ABC234), pushes seat_assigned then a
/// room snapshot, and settles the two pumps every other lobby test file in
/// this package uses. `addTearDown(controller.dispose)` is already
/// registered.
Future<RoomController> _mountTwoSeatLobby(
  WidgetTester tester, {
  required int mySeat,
  required Locale locale,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = _newController(connector);
  addTearDown(controller.dispose);

  final bool amHost = mySeat == 0;
  await tester.pumpWidget(
    _lobbyHarness(
      LobbyScreen(
        controller: controller,
        action: amHost ? LobbyAction.create : LobbyAction.join,
        code: amHost ? null : 'ABC234',
        playerName: 'Me',
        players: 2,
      ),
      locale: locale,
    ),
  );
  await tester.pump();
  expect(
    transport.sentRaw,
    isNotEmpty,
    reason:
        'fixture: expected LobbyScreen.initState to have sent exactly one '
        'request (createRoom or joinRoom) by now; sentRaw is empty',
  );
  final String requestId = _idOf(transport.sentRaw.last);

  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': mySeat, 'seat_token': 'tok-$mySeat'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: requestId,
      data: _roomJson(
        hostSeat: 0,
        players: 2,
        seats: <Map<String, Object?>>[
          _seatJson(0, name: 'Sam', connected: true),
          _seatJson(1, name: 'Dee', connected: true),
        ],
      ),
    ),
  );
  await tester.pump();
  await tester.pump();

  expect(
    controller.phase,
    RoomPhase.connected,
    reason:
        'fixture: expected RoomPhase.connected after the seat_assigned/room '
        'pair; it is ${controller.phase}',
  );
  return controller;
}

// ---------------------------------------------------------------------------
// Home mounting, copied from test/home_rule_toggles_test.dart's own idiom.
// ---------------------------------------------------------------------------

RoomController _throwingFactory() {
  return RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: (Uri url) async {
      throw StateError(
        'house_rules_test: this connector must not be asked '
        'to open a transport',
      );
    },
  );
}

Widget _homeScreenApp({
  RoomControllerFactory? controllerFactory,
  required Locale locale,
}) {
  return MaterialApp(
    theme: buildAppTheme(),
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: HomeScreen(
      onToggleLocale: () {},
      controllerFactory: controllerFactory ?? _throwingFactory,
    ),
  );
}

void main() {
  // ===========================================================================
  // 1: no widget with any of the four removed keys exists on home (rules
  // disclosure open) or in the lobby (host and guest).
  // ===========================================================================
  group(
    'C-356 acceptance 1: the four removed keys have no widget anywhere',
    () {
      testWidgets('home: no home-rule-blocks', (tester) async {
        await tester.pumpWidget(_homeScreenApp(locale: const Locale('en')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(_blocksSwitchKey),
          findsNothing,
          reason: 'C-356: home-rule-blocks must not exist anywhere on home',
        );
        expect(
          find.byKey(const Key('create-room-button')),
          findsOneWidget,
          reason:
              'fixture: create-room-button must exist, or this case is not '
              'actually looking at the home screen',
        );
      });

      testWidgets(
        'lobby, host: no lobby-rule-blocks or lobby-rule-blocks-chip',
        (tester) async {
          final RoomController controller = await _mountTwoSeatLobby(
            tester,
            mySeat: 0,
            locale: const Locale('en'),
          );
          expect(controller.isHost, isTrue, reason: 'fixture: host view');

          expect(find.byKey(_lobbyRuleBlocksKey), findsNothing);
          expect(find.byKey(_lobbyRuleBlocksChipKey), findsNothing);
        },
      );

      testWidgets(
        'lobby, guest: no lobby-rule-blocks or lobby-rule-blocks-chip',
        (tester) async {
          final RoomController controller = await _mountTwoSeatLobby(
            tester,
            mySeat: 1,
            locale: const Locale('en'),
          );
          expect(controller.isHost, isFalse, reason: 'fixture: guest view');

          expect(find.byKey(_lobbyRuleBlocksKey), findsNothing);
          expect(find.byKey(_lobbyRuleBlocksChipKey), findsNothing);
        },
      );
    },
  );

  // ===========================================================================
  // 4: RoomToggles().toJson() == {'capture_bonus': true}. The create frame a
  // host sent after turning capture bonus off went with the toggle (C-523 D1).
  // ===========================================================================
  group('C-356 acceptance 4: RoomToggles on the wire', () {
    test("RoomToggles().toJson() equals {'capture_bonus': true}", () {
      expect(
        const RoomToggles().toJson(),
        equals(<String, Object?>{'capture_bonus': true}),
      );
    });
  });

  // ===========================================================================
  // 5: at text scale 2.0 on 360x640 the lobby still passes C-347's own
  // large-text claim (seat names whole, no FlutterError), with the new line
  // present. Harness copied from test/large_text_lobby_names_test.dart.
  // ===========================================================================
  group('C-356 acceptance 5: large text 2.0 on 360x640, no rules line', () {
    const String mySeatName = 'Karim12345';
    const String otherSeatName = 'Samantha12';

    Future<void> loadAppFonts() async {
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

      final FontLoader notoSansArabic = FontLoader('Noto Sans Arabic');
      for (final String asset in const <String>[
        'fonts/NotoSansArabic-Regular.ttf',
        'fonts/NotoSansArabic-Bold.ttf',
      ]) {
        notoSansArabic.addFont(rootBundle.load(asset));
      }
      await notoSansArabic.load();
    }

    setUpAll(loadAppFonts);

    String textOf(Text text) => text.data ?? text.textSpan?.toPlainText() ?? '';

    Finder textFinderByData(Finder scope, String value) => find.descendant(
      of: scope,
      matching: find.byWidgetPredicate(
        (Widget widget) => widget is Text && textOf(widget) == value,
      ),
    );

    RenderParagraph paragraphOf(WidgetTester tester, Finder textFinder) {
      final Finder rich = find.descendant(
        of: textFinder,
        matching: find.byType(RichText),
      );
      return tester.renderObject<RenderParagraph>(rich);
    }

    for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
      testWidgets(
        '${locale.languageCode} 360x640 scale 2.0: seat names whole, no '
        'FlutterError, lobby-house-rules absent',
        (tester) async {
          tester.view.physicalSize = const Size(360, 640);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          final List<FlutterErrorDetails> captured = <FlutterErrorDetails>[];
          final void Function(FlutterErrorDetails)? previous =
              FlutterError.onError;
          FlutterError.onError = captured.add;

          final _Connector connector = _Connector();
          final FakeTransport transport = FakeTransport();
          connector.enqueue(transport);
          final RoomController controller = _newController(connector);
          addTearDown(controller.dispose);

          try {
            await tester.pumpWidget(
              MaterialApp(
                theme: buildAppTheme(),
                locale: locale,
                supportedLocales: appSupportedLocales,
                localizationsDelegates: const [
                  AppLocalizations.delegate,
                  GlobalMaterialLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                ],
                builder: (BuildContext context, Widget? screen) {
                  final MediaQueryData data = MediaQuery.of(context);
                  return MediaQuery(
                    data: data.copyWith(
                      textScaler: const TextScaler.linear(2.0),
                    ),
                    child: screen!,
                  );
                },
                home: LobbyScreen(
                  controller: controller,
                  action: LobbyAction.create,
                  playerName: mySeatName,
                  players: 2,
                ),
              ),
            );
            await tester.pump();
            expect(transport.sentRaw, isNotEmpty);
            final String requestId = _idOf(transport.sentRaw.last);
            transport.pushText(
              _frame(
                type: 'seat_assigned',
                data: <String, Object?>{'seat': 0, 'seat_token': 'tok-0'},
              ),
            );
            transport.pushText(
              _frame(
                type: 'room',
                re: requestId,
                data: _roomJson(
                  hostSeat: 0,
                  players: 2,
                  seats: <Map<String, Object?>>[
                    _seatJson(0, name: mySeatName),
                    _seatJson(1, name: otherSeatName),
                  ],
                ),
              ),
            );
            await tester.pump();
            await tester.pump();
          } finally {
            FlutterError.onError = previous;
          }

          expect(
            captured,
            isEmpty,
            reason:
                '${locale.languageCode}: mounting the lobby at scale 2.0 '
                'on 360x640 with no house-rules line must raise '
                'no FlutterError, got ${captured.length}: '
                '${captured.map((e) => e.exceptionAsString()).join('; ')}',
          );

          for (final (int seat, String name) in <(int, String)>[
            (0, mySeatName),
            (1, otherSeatName),
          ]) {
            final Finder card = find.byKey(Key('lobby-seat-$seat'));
            expect(
              card,
              findsOneWidget,
              reason: 'fixture: lobby-seat-$seat must be on screen',
            );
            final Finder nameText = textFinderByData(card, name);
            expect(
              nameText,
              findsOneWidget,
              reason:
                  'fixture: seat $seat name text "$name" must be inside '
                  'lobby-seat-$seat',
            );
            final bool ellipsized = paragraphOf(
              tester,
              nameText,
            ).didExceedMaxLines;
            expect(
              ellipsized,
              isFalse,
              reason:
                  '${locale.languageCode}: C-347 still holds -- seat $seat '
                  'name "$name" must not be ellipsized at scale 2.0 on '
                  '360x640 with no house-rules line on screen',
            );
          }

          expect(
            find.byKey(_lobbyHouseRulesKey),
            findsNothing,
            reason:
                '${locale.languageCode}: C-523 D6 removed lobby-house-rules; '
                'it must not be on screen at scale 2.0 on 360x640',
          );
        },
      );
    }
  });
}
