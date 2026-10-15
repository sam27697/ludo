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
// Five groups below, one per C-356 acceptance bullet:
//   1. no widget with any of the four removed keys (home-rule-blocks,
//      lobby-rule-blocks, lobby-rule-blocks-chip) exists on home with the
//      rules disclosure open, or in the lobby, host or guest;
//   2. home-house-rules and lobby-house-rules show exactly the en and ar
//      literals the contract quotes, in a 2-player lobby as host and guest;
//   3. the capture-bonus hint reads the contract's new en/ar strings;
//   4. RoomToggles().toJson() == {'capture_bonus': true}, and a host's
//      create frame after turning capture bonus off carries
//      rules == {'capture_bonus': false};
//   5. at text scale 2.0 on 360x640 the lobby still passes C-347's own
//      large-text claim (seat names whole, no FlutterError) with the new
//      line present.
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

// The contract's own literals (work/ludo/orders/C-356-house-rules-client.md,
// decisions 4 and 5), quoted verbatim, never looked up through
// AppLocalizations.
const String _houseRulesLineEn =
    'Two tokens on one square are safe from capture. A token reaching home '
    'earns another roll.';
const String _houseRulesLineAr =
    'قطعتان على مربع واحد لا تُؤكلان. وصول قطعة إلى البيت يمنحك رمية أخرى.';
const String _captureBonusHintEn = 'Capturing a token earns another roll';
const String _captureBonusHintAr = 'أكل قطعة خصم يمنحك رمية أخرى';

const Key _blocksSwitchKey = Key('home-rule-blocks');
const Key _captureSwitchKey = Key('home-rule-capture-bonus');
const Key _homeHouseRulesKey = Key('home-house-rules');
const Key _lobbyHouseRulesKey = Key('lobby-house-rules');
const Key _lobbyRuleBlocksKey = Key('lobby-rule-blocks');
const Key _lobbyRuleBlocksChipKey = Key('lobby-rule-blocks-chip');
const Key _disclosureKey = Key('home-players-disclosure');
const Key _createButtonKey = Key('create-room-button');

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

class _LiveControllerFactory {
  final List<RoomController> controllers = <RoomController>[];
  final List<FakeTransport> transports = <FakeTransport>[];

  RoomController call() {
    final RoomController created = RoomController(
      serverUrl: Uri.parse(_testUrl),
      connect: (Uri url) async {
        final FakeTransport transport = FakeTransport();
        transports.add(transport);
        return transport;
      },
    );
    controllers.add(created);
    return created;
  }
}

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

Future<void> _openPlayersDisclosure(WidgetTester tester) async {
  final Finder disclosure = find.byKey(_disclosureKey);
  expect(
    disclosure,
    findsOneWidget,
    reason:
        'home-players-disclosure must be on screen to open the rules '
        'under it',
  );
  await tester.ensureVisible(disclosure);
  await tester.tap(disclosure);
  await tester.pumpAndSettle();
}

Future<void> _tapAndAwaitPushedRoute(WidgetTester tester, Key buttonKey) async {
  await tester.tap(find.byKey(buttonKey));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

List<Map<String, Object?>> _decodeSent(FakeTransport transport) => transport
    .sentRaw
    .map((String raw) => jsonDecode(raw) as Map<String, Object?>)
    .toList();

/// Reads the Text found at [key], whether the key sits directly on the Text
/// widget or on an ancestor of it (matchRoot: true covers both), the same
/// defensive idiom test/board_test.dart and test/token_travel_test.dart
/// already use for "this key shows this text" claims without assuming which
/// widget the key is actually painted on.
void _expectKeyShowsText(
  WidgetTester tester,
  Key key,
  String expected, {
  required String reason,
}) {
  final Finder root = find.byKey(key);
  expect(root, findsOneWidget, reason: '$reason (key not found at all)');
  final Finder textMatch = find.descendant(
    of: root,
    matching: find.text(expected),
    matchRoot: true,
  );
  expect(textMatch, findsOneWidget, reason: reason);
}

void main() {
  // ===========================================================================
  // 1: no widget with any of the four removed keys exists on home (rules
  // disclosure open) or in the lobby (host and guest).
  // ===========================================================================
  group(
    'C-356 acceptance 1: the four removed keys have no widget anywhere',
    () {
      testWidgets('home, rules disclosure open: no home-rule-blocks', (
        tester,
      ) async {
        await tester.pumpWidget(_homeScreenApp(locale: const Locale('en')));
        await tester.pumpAndSettle();
        await _openPlayersDisclosure(tester);

        expect(
          find.byKey(_blocksSwitchKey),
          findsNothing,
          reason:
              'C-356: home-rule-blocks must not exist anywhere on home, '
              'including with the rules disclosure open',
        );
        expect(
          find.byKey(_captureSwitchKey),
          findsOneWidget,
          reason:
              'fixture: home-rule-capture-bonus must still exist, or this '
              'case is not actually looking at the open rules disclosure',
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
  // 2: home-house-rules and lobby-house-rules show exactly the en and ar
  // strings the contract quotes, in a 2-player lobby as host and as guest.
  // ===========================================================================
  group('C-356 acceptance 2: the house-rules line, literal text', () {
    for (final (String localeName, Locale locale, String expected)
        in <(String, Locale, String)>[
          ('en', Locale('en'), _houseRulesLineEn),
          ('ar', Locale('ar'), _houseRulesLineAr),
        ]) {
      testWidgets('home, $localeName: home-house-rules reads the literal', (
        tester,
      ) async {
        await tester.pumpWidget(_homeScreenApp(locale: locale));
        await tester.pumpAndSettle();
        await _openPlayersDisclosure(tester);

        _expectKeyShowsText(
          tester,
          _homeHouseRulesKey,
          expected,
          reason:
              '$localeName: home-house-rules must show exactly '
              '"$expected"',
        );
      });

      testWidgets(
        'lobby host, $localeName: lobby-house-rules reads the literal',
        (tester) async {
          await _mountTwoSeatLobby(tester, mySeat: 0, locale: locale);

          _expectKeyShowsText(
            tester,
            _lobbyHouseRulesKey,
            expected,
            reason:
                '$localeName (host): lobby-house-rules must show exactly '
                '"$expected"',
          );
        },
      );

      testWidgets(
        'lobby guest, $localeName: lobby-house-rules reads the literal',
        (tester) async {
          await _mountTwoSeatLobby(tester, mySeat: 1, locale: locale);

          _expectKeyShowsText(
            tester,
            _lobbyHouseRulesKey,
            expected,
            reason:
                '$localeName (guest): lobby-house-rules must show exactly '
                '"$expected"',
          );
        },
      );
    }
  });

  // ===========================================================================
  // 3: the capture-bonus hint reads the new strings in both locales.
  // ===========================================================================
  group('C-356 acceptance 3: the reworded capture-bonus hint', () {
    for (final (String localeName, Locale locale, String expected)
        in <(String, Locale, String)>[
          ('en', Locale('en'), _captureBonusHintEn),
          ('ar', Locale('ar'), _captureBonusHintAr),
        ]) {
      testWidgets(
        '$localeName: home-rule-capture-bonus.hint reads the new string',
        (tester) async {
          await tester.pumpWidget(_homeScreenApp(locale: locale));
          await tester.pumpAndSettle();
          await _openPlayersDisclosure(tester);

          final Finder captureSwitch = find.byKey(_captureSwitchKey);
          expect(captureSwitch, findsOneWidget);
          final HomeRuleToggle card = tester.widget<HomeRuleToggle>(
            captureSwitch,
          );
          expect(
            card.hint,
            expected,
            reason:
                '$localeName: homeRuleCaptureBonusHint must now read '
                '"$expected" (no more "home" meaning the yard), got '
                '"${card.hint}"',
          );
        },
      );
    }
  });

  // ===========================================================================
  // 4: RoomToggles().toJson() == {'capture_bonus': true}, and the create
  // frame a host sends after turning capture bonus off carries
  // rules == {'capture_bonus': false}.
  // ===========================================================================
  group('C-356 acceptance 4: RoomToggles on the wire', () {
    test("RoomToggles().toJson() equals {'capture_bonus': true}", () {
      expect(
        const RoomToggles().toJson(),
        equals(<String, Object?>{'capture_bonus': true}),
      );
    });

    testWidgets('a host turning capture bonus off before Create sends rules == '
        "{'capture_bonus': false}", (tester) async {
      final _LiveControllerFactory factory = _LiveControllerFactory();
      await tester.pumpWidget(
        _homeScreenApp(
          controllerFactory: factory.call,
          locale: const Locale('en'),
        ),
      );
      await tester.pumpAndSettle();
      await _openPlayersDisclosure(tester);

      await tester.tap(find.byKey(_captureSwitchKey));
      await tester.pump();

      await _tapAndAwaitPushedRoute(tester, _createButtonKey);

      expect(factory.transports, hasLength(1));
      final List<Map<String, Object?>> sent = _decodeSent(
        factory.transports.single,
      );
      expect(sent, hasLength(1));
      expect(sent.single['t'], 'create_room');
      final Map<String, Object?> data =
          sent.single['d']! as Map<String, Object?>;
      expect(
        data['rules'],
        equals(<String, Object?>{'capture_bonus': false}),
        reason:
            'expected the create_room frame\'s rules to be exactly '
            "{'capture_bonus': false}; got ${data['rules']}",
      );

      // Drain the still-open request's timeout so flutter_test does not
      // find a pending timer at teardown, the same reasoning
      // test/home_rule_toggles_test.dart's own
      // _drainPendingRequestTimeout documents.
      await tester.pump(const Duration(seconds: 11));
      await tester.pump();
    });
  });

  // ===========================================================================
  // 5: at text scale 2.0 on 360x640 the lobby still passes C-347's own
  // large-text claim (seat names whole, no FlutterError), with the new line
  // present. Harness copied from test/large_text_lobby_names_test.dart.
  // ===========================================================================
  group('C-356 acceptance 5: large text 2.0 on 360x640, line present', () {
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
        'FlutterError, lobby-house-rules present',
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
                'on 360x640 with the house-rules line present must raise '
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
                  '360x640 with the new house-rules line on screen',
            );
          }

          expect(
            find.byKey(_lobbyHouseRulesKey),
            findsOneWidget,
            reason:
                '${locale.languageCode}: lobby-house-rules must still be '
                'on screen at scale 2.0 on 360x640',
          );
        },
      );
    }
  });
}
