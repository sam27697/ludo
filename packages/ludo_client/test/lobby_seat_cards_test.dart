// Proof for contract C-254 ("the lobby: seats as seat cards, rules as icon
// chips"), rules 1 through 5 and rule 7, written from
// work/ludo/orders/C-254-lobby-seats.md directly, against no implementation
// of any of it: on this branch lib/src/lobby_screen.dart still renders each
// seated player as a bare centred line of text under key
// `lobby-seat-<n>`, mounts `SeatPipStrip` with no `seats:` argument (so it
// always draws all four colours), and renders the two rule lines as plain
// `Text` with no `Icon`. Every key this file asks for --
// `lobby-seat-<n>-token`, `lobby-seat-<n>-you`, `lobby-seat-<n>-host`,
// `lobby-seat-open-<i>`, an `Icon` inside `lobby-rule-blocks` /
// `lobby-rule-capture-bonus` -- is therefore absent, and every case below is
// red on this base (ac19bb3, the mutant C-254's own run names). Order 255
// itself does not implement C-254; order 254 does, in parallel, on a
// different worktree.
//
// Driven the same way test/lobby_start_with_present_test.dart drives
// LobbyScreen: a real RoomController over a FakeTransport
// (test/net/fake_transport.dart, read-only, not edited here), never a mock
// of RoomController. The connector double, the frame builder and the JSON
// fixtures below are copied from that file's own idiom (and from
// test/lobby_signature_chrome_test.dart's colour-reading helpers) rather
// than imported, since none of it is exported by those files and neither
// is on this order's file list to modify.
//
// The two new strings C-254 rule 2 and rule 6 introduce, `lobbyOpenSeat`
// and `seatYou`, do not exist as getters on `AppLocalizations` on this
// base. Read through a `dynamic` lookup here (`_dynString` below) rather
// than `loc.lobbyOpenSeat` / `loc.seatYou` directly, so this file still
// compiles and `flutter analyze` still reports 0 on this base; the dynamic
// lookup itself throws `NoSuchMethodError` at run time until C-254 adds
// the getters, which is exactly the red this file is written to show.
// Chosen over comparing against the bare literals ("Waiting for a friend" /
// "بانتظار صديق" and "You" / "أنت") so this file keeps proving the right
// thing (the getter exists and reads the frame's own locale) once C-254
// lands, rather than freezing today's wording.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://example.test/ws';

// --- server-side id generation for pushed frames ---------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'seat-cards-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

// --- small JSON helpers, mirroring lobby_start_with_present_test.dart ------

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

// --- a minimal valid docs/PROTOCOL.md section 6 room snapshot --------------

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
  String code = 'ABC234',
  String state = 'LOBBY',
  int hostSeat = 0,
  required int players,
  required List<Map<String, Object?>> seats,
  bool blocks = true,
  bool captureBonus = true,
  Map<String, Object?>? rematch,
  int seq = 1,
}) => <String, Object?>{
  'code': code,
  'state': state,
  'host_seat': hostSeat,
  'players': players,
  'rules': <String, Object?>{
    'blocks': blocks,
    'capture_bonus': captureBonus,
    'turn_seconds': 45,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': null,
  'client_seeds': null,
  'seats': seats,
  'turn': null,
  'winner': null,
  'rematch': rematch,
  'seq': seq,
};

// --- a TransportConnector test double, copied from
// --- lobby_start_with_present_test.dart's own idiom rather than imported:
// --- it is not exported by that file, and that file is not on this order's
// --- file list to modify. -------------------------------------------------

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

RoomController _newController(_Connector connector) =>
    RoomController(serverUrl: Uri.parse(_testUrl), connect: connector.call);

// --- widget harness ----------------------------------------------------

Widget _harness(
  Widget child, {
  Locale locale = const Locale('en'),
  double textScale = 1.0,
}) {
  return MaterialApp(
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
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
    home: child,
  );
}

// --- mounting a connected lobby ---------------------------------------------

/// Mounts `LobbyScreen` as [mySeat] (host when [mySeat] == [hostSeat],
/// otherwise a guest joining room `ABC234`), pushes `seat_assigned` then a
/// `room` snapshot built from [seats], [players], [hostSeat], [blocks],
/// [captureBonus] and [rematch], and settles the two pumps every other
/// lobby test file in this package uses before asserting on the connected
/// body. Returns the controller so a test can read `room`/`isHost`/`seat`
/// directly; `addTearDown(controller.dispose)` is already registered.
Future<RoomController> _mountConnectedLobby(
  WidgetTester tester, {
  required int mySeat,
  int hostSeat = 0,
  required int players,
  required List<Map<String, Object?>> seats,
  bool blocks = true,
  bool captureBonus = true,
  Map<String, Object?>? rematch,
  String roomState = 'LOBBY',
  Locale locale = const Locale('en'),
  double textScale = 1.0,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = _newController(connector);
  addTearDown(controller.dispose);

  final bool amHost = mySeat == hostSeat;
  await tester.pumpWidget(
    _harness(
      LobbyScreen(
        controller: controller,
        action: amHost ? LobbyAction.create : LobbyAction.join,
        code: amHost ? null : 'ABC234',
        playerName: 'Me',
        players: players,
      ),
      locale: locale,
      textScale: textScale,
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
        state: roomState,
        hostSeat: hostSeat,
        players: players,
        seats: seats,
        blocks: blocks,
        captureBonus: captureBonus,
        rematch: rematch,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();

  expect(
    controller.phase,
    RoomPhase.connected,
    reason:
        'fixture: expected the controller to reach RoomPhase.connected '
        'after the seat_assigned/room pair; it is ${controller.phase}',
  );
  return controller;
}

// --- colour reading, copied from lobby_signature_chrome_test.dart's own
// --- idiom (private there, so copied rather than imported) -----------------

Color? _solidColorOf(Widget widget) {
  if (widget is ColoredBox) {
    return widget.color;
  }
  if (widget is Material) {
    return widget.color;
  }
  if (widget is Container) {
    final Decoration? decoration = widget.decoration;
    if (decoration is BoxDecoration && decoration.color != null) {
      return decoration.color;
    }
    return widget.color;
  }
  if (widget is DecoratedBox) {
    final Decoration decoration = widget.decoration;
    if (decoration is BoxDecoration) {
      return decoration.color;
    }
  }
  return null;
}

Color _requireColor(WidgetTester tester, Finder finder, String label) {
  expect(finder, findsOneWidget, reason: '$label must be present');
  final Color? found = _solidColorOf(tester.widget(finder));
  if (found != null) {
    return found;
  }
  final Element root = tester.element(finder);
  Color? childColor;
  void visit(Element element) {
    if (childColor != null) {
      return;
    }
    childColor = _solidColorOf(element.widget);
    if (childColor == null) {
      element.visitChildren(visit);
    }
  }

  root.visitChildren(visit);
  expect(
    childColor,
    isNotNull,
    reason: '$label must expose a solid colour on itself or a descendant',
  );
  return childColor!;
}

/// Reads a string getter that does not exist as a static member of
/// `AppLocalizations` on this base (`lobbyOpenSeat`, `seatYou`) through a
/// `dynamic` call, so this file compiles and analyzes clean today and
/// throws at run time (red) until C-254 adds the getter. See the file
/// header for why this was chosen over pinning the bare literal.
String _dynString(AppLocalizations loc, String getterName) {
  final dynamic dynLoc = loc;
  final Object? value = switch (getterName) {
    'lobbyOpenSeat' => dynLoc.lobbyOpenSeat,
    'seatYou' => dynLoc.seatYou,
    _ => throw ArgumentError('unknown dynamic getter "$getterName"'),
  };
  if (value is! String) {
    fail(
      'expected loc.$getterName to be a String once C-254 adds it, got '
      '$value',
    );
  }
  return value;
}

/// True for a widget keyed `lobby-seat-open-<i>`, i any non-negative
/// integer. Deliberately excludes `lobby-seat-<n>`, `lobby-seat-<n>-token`,
/// `lobby-seat-<n>-you` and `lobby-seat-<n>-host`: none of those start with
/// `lobby-seat-open-`.
final RegExp _openSeatKeyPattern = RegExp(r'^lobby-seat-open-\d+$');

Finder _openSeatCards() => find.byWidgetPredicate((Widget widget) {
  final Key? key = widget.key;
  return key is ValueKey<String> && _openSeatKeyPattern.hasMatch(key.value);
});

/// Reads the single `Icon` inside the chip keyed [chipKey], failing with a
/// reason naming the chip and what was expected rather than letting
/// `tester.widget` throw a bare `Bad state: No element` when C-254's icon
/// is not there yet.
IconData _iconInChip(WidgetTester tester, String chipKey) {
  final Finder iconFinder = find.descendant(
    of: find.byKey(Key(chipKey)),
    matching: find.byType(Icon),
  );
  expect(
    iconFinder,
    findsOneWidget,
    reason: 'rule 4: $chipKey must contain exactly one Icon',
  );
  final IconData? icon = tester.widget<Icon>(iconFinder).icon;
  expect(
    icon,
    isNotNull,
    reason: 'rule 4: $chipKey\'s Icon must carry a non-null IconData',
  );
  return icon!;
}

bool _isOverflowError(FlutterErrorDetails details) {
  final String text = '${details.exception}\n$details';
  return text.contains('overflowed') ||
      text.contains('A RenderFlex overflowed');
}

void main() {
  // ===========================================================================
  // Rule 1: seat cards -- disc colour, the You chip, the host crown, the
  // disconnected wifi-off icon.
  // ===========================================================================
  group('C-254 rule 1: seat cards', () {
    // Priya (seat 0, me, host, connected), Karim (seat 1, disconnected),
    // Lina (seat 2, connected) -- 3 of 4 seats, so rule 2's open-seat card
    // for seat 3 is also on screen but not asserted on here.
    List<Map<String, Object?>> threeSeatsOneOffline() => <Map<String, Object?>>[
      _seatJson(0, name: 'Priya', connected: true),
      _seatJson(1, name: 'Karim', connected: false),
      _seatJson(2, name: 'Lina', connected: true),
    ];

    testWidgets(
      'lobby-seat-<n>-token is a disc coloured LudoColors.seats[n] at full '
      'alpha, for every occupied seat',
      (tester) async {
        await _mountConnectedLobby(
          tester,
          mySeat: 0,
          hostSeat: 0,
          players: 4,
          seats: threeSeatsOneOffline(),
        );

        for (final int seat in <int>[0, 1, 2]) {
          final Finder tokenFinder = find.byKey(Key('lobby-seat-$seat-token'));
          final Color colour = _requireColor(
            tester,
            tokenFinder,
            'lobby-seat-$seat-token',
          );
          expect(
            colour,
            LudoColors.seats[seat],
            reason:
                'rule 1: lobby-seat-$seat-token must be LudoColors.seats'
                '[$seat] (${LudoColors.seats[seat]}) at full alpha, got '
                '$colour',
          );
        }
      },
    );

    testWidgets('lobby-seat-<n>-you exists exactly on my own seat', (
      tester,
    ) async {
      final RoomController controller = await _mountConnectedLobby(
        tester,
        mySeat: 0,
        hostSeat: 0,
        players: 4,
        seats: threeSeatsOneOffline(),
      );
      expect(controller.seat, 0, reason: 'fixture: must mount as seat 0');

      expect(
        find.byKey(const Key('lobby-seat-0-you')),
        findsOneWidget,
        reason: 'rule 1: lobby-seat-0-you must show on my own seat (0)',
      );
      expect(
        find.byKey(const Key('lobby-seat-1-you')),
        findsNothing,
        reason: 'rule 1: lobby-seat-1-you must not show on seat 1',
      );
      expect(
        find.byKey(const Key('lobby-seat-2-you')),
        findsNothing,
        reason: 'rule 1: lobby-seat-2-you must not show on seat 2',
      );
    });

    testWidgets('lobby-seat-<n>-host exists exactly on room.hostSeat', (
      tester,
    ) async {
      // A guest this time (seat 2), so the host marker is proven on a
      // seat other than my own seat too.
      final RoomController controller = await _mountConnectedLobby(
        tester,
        mySeat: 2,
        hostSeat: 0,
        players: 4,
        seats: threeSeatsOneOffline(),
      );
      expect(controller.seat, 2, reason: 'fixture: must mount as seat 2');
      expect(controller.isHost, isFalse, reason: 'fixture: guest view');

      expect(
        find.byKey(const Key('lobby-seat-0-host')),
        findsOneWidget,
        reason: 'rule 1: lobby-seat-0-host must show on room.hostSeat (0)',
      );
      expect(
        find.byKey(const Key('lobby-seat-1-host')),
        findsNothing,
        reason: 'rule 1: lobby-seat-1-host must not show on seat 1',
      );
      expect(
        find.byKey(const Key('lobby-seat-2-host')),
        findsNothing,
        reason: 'rule 1: lobby-seat-2-host must not show on seat 2',
      );
    });

    testWidgets('a disconnected seat shows Icons.wifi_off inside its card, a '
        'connected one does not', (tester) async {
      await _mountConnectedLobby(
        tester,
        mySeat: 0,
        hostSeat: 0,
        players: 4,
        seats: threeSeatsOneOffline(),
      );

      Finder wifiOffIn(int seat) => find.descendant(
        of: find.byKey(Key('lobby-seat-$seat')),
        matching: find.byWidgetPredicate(
          (Widget widget) => widget is Icon && widget.icon == Icons.wifi_off,
        ),
      );

      expect(
        wifiOffIn(1),
        findsOneWidget,
        reason:
            'rule 1: seat 1 (Karim, connected: false) must show '
            'Icons.wifi_off inside lobby-seat-1',
      );
      expect(
        wifiOffIn(0),
        findsNothing,
        reason: 'rule 1: seat 0 (connected: true) must not show Icons.wifi_off',
      );
      expect(
        wifiOffIn(2),
        findsNothing,
        reason:
            'rule 1: seat 2 (Lina, connected: true) must not show '
            'Icons.wifi_off',
      );
    });
  });

  // ===========================================================================
  // Rule 2: open seats -- one placeholder card per unseated seat, keyed and
  // worded, and none at all in a full room.
  // ===========================================================================
  group('C-254 rule 2: open seats', () {
    testWidgets(
      'a 4-player room with 2 seated shows exactly two lobby-seat-open-* '
      'cards and the lobbyOpenSeat string twice',
      (tester) async {
        final RoomController controller = await _mountConnectedLobby(
          tester,
          mySeat: 0,
          hostSeat: 0,
          players: 4,
          seats: <Map<String, Object?>>[
            _seatJson(0, name: 'Priya', connected: true),
            _seatJson(1, name: 'Karim', connected: true),
          ],
        );
        expect(
          controller.room!.players - controller.room!.seats.length,
          2,
          reason: 'fixture: 4 players, 2 seated, must leave 2 seats open',
        );

        expect(
          _openSeatCards(),
          findsNWidgets(2),
          reason:
              'rule 2: a 4-player room with 2 seated must show exactly two '
              'lobby-seat-open-<i> cards',
        );

        final AppLocalizations loc = AppLocalizations.of(
          tester.element(find.byType(LobbyScreen)),
        );
        final String openSeatText = _dynString(loc, 'lobbyOpenSeat');
        expect(
          find.text(openSeatText),
          findsNWidgets(2),
          reason:
              'rule 2: the lobbyOpenSeat string ("$openSeatText") must show '
              'exactly twice, once per open seat',
        );
      },
    );

    testWidgets('a full room shows no open-seat placeholders', (tester) async {
      final RoomController controller = await _mountConnectedLobby(
        tester,
        mySeat: 0,
        hostSeat: 0,
        players: 2,
        seats: <Map<String, Object?>>[
          _seatJson(0, name: 'Priya', connected: true),
          _seatJson(1, name: 'Karim', connected: true),
        ],
      );
      expect(
        controller.room!.seats.length,
        controller.room!.players,
        reason: 'fixture: needs a full room, 2 of 2',
      );

      expect(
        _openSeatCards(),
        findsNothing,
        reason: 'rule 2: a full room must show no lobby-seat-open-* cards',
      );

      final AppLocalizations loc = AppLocalizations.of(
        tester.element(find.byType(LobbyScreen)),
      );
      final String openSeatText = _dynString(loc, 'lobbyOpenSeat');
      expect(
        find.text(openSeatText),
        findsNothing,
        reason:
            'rule 2: a full room must show the lobbyOpenSeat string '
            'nowhere',
      );
    });
  });

  // ===========================================================================
  // Rule 3: the grid -- two columns in seat order, mirrored in Arabic, every
  // card at least 56dp tall.
  // ===========================================================================
  group('C-254 rule 3: the grid', () {
    List<Map<String, Object?>> twoSeats() => <Map<String, Object?>>[
      _seatJson(0, name: 'Priya', connected: true),
      _seatJson(1, name: 'Karim', connected: true),
    ];

    testWidgets('en: seat 0\'s card is left of seat 1\'s', (tester) async {
      await _mountConnectedLobby(
        tester,
        mySeat: 0,
        hostSeat: 0,
        players: 4,
        seats: twoSeats(),
      );

      final Rect seat0 = tester.getRect(find.byKey(const Key('lobby-seat-0')));
      final Rect seat1 = tester.getRect(find.byKey(const Key('lobby-seat-1')));
      expect(
        seat0.left,
        lessThan(seat1.left),
        reason:
            'rule 3: in en, seat 0\'s card must sit left of seat 1\'s; got '
            'seat0=$seat0, seat1=$seat1',
      );
    });

    testWidgets('ar: seat 0\'s card is right of seat 1\'s', (tester) async {
      final RoomController controller = await _mountConnectedLobby(
        tester,
        mySeat: 0,
        hostSeat: 0,
        players: 4,
        seats: twoSeats(),
        locale: const Locale('ar'),
      );

      expect(
        Directionality.of(tester.element(find.byType(LobbyScreen))),
        TextDirection.rtl,
        reason: 'fixture: Locale(ar) must resolve Directionality to rtl',
      );
      expect(controller.room!.seats.length, 2);

      final Rect seat0 = tester.getRect(find.byKey(const Key('lobby-seat-0')));
      final Rect seat1 = tester.getRect(find.byKey(const Key('lobby-seat-1')));
      expect(
        seat0.left,
        greaterThan(seat1.left),
        reason:
            'rule 3: in ar, seat order starts at the right, so seat 0\'s '
            'card must sit right of seat 1\'s; got seat0=$seat0, seat1=$seat1',
      );
    });

    testWidgets('every occupied seat card is at least 56dp tall', (
      tester,
    ) async {
      await _mountConnectedLobby(
        tester,
        mySeat: 0,
        hostSeat: 0,
        players: 4,
        seats: <Map<String, Object?>>[
          _seatJson(0, name: 'Priya', connected: true),
          _seatJson(1, name: 'Karim', connected: true),
          _seatJson(2, name: 'Lina', connected: true),
          _seatJson(3, name: 'Omar', connected: true),
        ],
      );

      for (final int seat in <int>[0, 1, 2, 3]) {
        final Rect rect = tester.getRect(find.byKey(Key('lobby-seat-$seat')));
        expect(
          rect.height,
          greaterThanOrEqualTo(56),
          reason:
              'rule 3: lobby-seat-$seat must be at least 56dp tall, got '
              '${rect.height}',
        );
      }
    });
  });

  // ===========================================================================
  // Rule 4: rule chips -- an icon plus the unchanged label, on and off
  // differing by icon, not only by colour.
  // ===========================================================================
  group('C-254 rule 4: rule chips', () {
    List<Map<String, Object?>> oneSeat() => <Map<String, Object?>>[
      _seatJson(0, name: 'Priya', connected: true),
    ];

    testWidgets(
      'lobby-rule-blocks contains an Icon and the unchanged on-label',
      (tester) async {
        final RoomController controller = await _mountConnectedLobby(
          tester,
          mySeat: 0,
          hostSeat: 0,
          players: 4,
          seats: oneSeat(),
          blocks: true,
        );
        expect(controller.room!.rules.blocks, isTrue);

        final Finder chip = find.byKey(const Key('lobby-rule-blocks'));
        expect(
          find.descendant(of: chip, matching: find.byType(Icon)),
          findsOneWidget,
          reason: 'rule 4: lobby-rule-blocks must contain an Icon',
        );

        final AppLocalizations loc = AppLocalizations.of(
          tester.element(find.byType(LobbyScreen)),
        );
        expect(
          find.descendant(of: chip, matching: find.text(loc.lobbyRuleBlocksOn)),
          findsOneWidget,
          reason:
              'rule 4: lobby-rule-blocks must still contain the unchanged '
              'loc.lobbyRuleBlocksOn string ("${loc.lobbyRuleBlocksOn}")',
        );
      },
    );

    testWidgets('lobby-rule-capture-bonus contains an Icon and the unchanged '
        'off-label', (tester) async {
      final RoomController controller = await _mountConnectedLobby(
        tester,
        mySeat: 0,
        hostSeat: 0,
        players: 4,
        seats: oneSeat(),
        captureBonus: false,
      );
      expect(controller.room!.rules.captureBonus, isFalse);

      final Finder chip = find.byKey(const Key('lobby-rule-capture-bonus'));
      expect(
        find.descendant(of: chip, matching: find.byType(Icon)),
        findsOneWidget,
        reason: 'rule 4: lobby-rule-capture-bonus must contain an Icon',
      );

      final AppLocalizations loc = AppLocalizations.of(
        tester.element(find.byType(LobbyScreen)),
      );
      expect(
        find.descendant(
          of: chip,
          matching: find.text(loc.lobbyRuleCaptureBonusOff),
        ),
        findsOneWidget,
        reason:
            'rule 4: lobby-rule-capture-bonus must still contain the '
            'unchanged loc.lobbyRuleCaptureBonusOff string '
            '("${loc.lobbyRuleCaptureBonusOff}")',
      );
    });

    testWidgets('blocks on vs off use different icons, not only colour', (
      tester,
    ) async {
      await _mountConnectedLobby(
        tester,
        mySeat: 0,
        hostSeat: 0,
        players: 4,
        seats: oneSeat(),
        blocks: true,
      );
      final IconData onIcon = _iconInChip(tester, 'lobby-rule-blocks');

      await _mountConnectedLobby(
        tester,
        mySeat: 0,
        hostSeat: 0,
        players: 4,
        seats: oneSeat(),
        blocks: false,
      );
      final IconData offIcon = _iconInChip(tester, 'lobby-rule-blocks');

      expect(
        onIcon,
        isNot(equals(offIcon)),
        reason:
            'rule 4: lobby-rule-blocks on ($onIcon) and off ($offIcon) '
            'must use different icons, not only a colour change',
      );
    });

    testWidgets(
      'capture bonus on vs off use different icons, not only colour',
      (tester) async {
        await _mountConnectedLobby(
          tester,
          mySeat: 0,
          hostSeat: 0,
          players: 4,
          seats: oneSeat(),
          captureBonus: true,
        );
        final IconData onIcon = _iconInChip(tester, 'lobby-rule-capture-bonus');

        await _mountConnectedLobby(
          tester,
          mySeat: 0,
          hostSeat: 0,
          players: 4,
          seats: oneSeat(),
          captureBonus: false,
        );
        final IconData offIcon = _iconInChip(
          tester,
          'lobby-rule-capture-bonus',
        );

        expect(
          onIcon,
          isNot(equals(offIcon)),
          reason:
              'rule 4: lobby-rule-capture-bonus on ($onIcon) and off '
              '($offIcon) must use different icons, not only a colour '
              'change',
        );
      },
    );
  });

  // ===========================================================================
  // Rule 5: the pip strip shows exactly the occupied seats.
  // ===========================================================================
  group('C-254 rule 5: pip strip', () {
    testWidgets(
      'a 4-player room with seats 0 and 1 occupied shows pips 0 and 1 only',
      (tester) async {
        final RoomController controller = await _mountConnectedLobby(
          tester,
          mySeat: 0,
          hostSeat: 0,
          players: 4,
          seats: <Map<String, Object?>>[
            _seatJson(0, name: 'Priya', connected: true),
            _seatJson(1, name: 'Karim', connected: true),
          ],
        );
        expect(controller.room!.seats.map((s) => s.seat).toList(), <int>[
          0,
          1,
        ], reason: 'fixture: occupied seats must be exactly [0, 1]');

        final Finder lobbyScope = find.byType(LobbyScreen);
        for (final int seat in <int>[0, 1]) {
          expect(
            find.descendant(
              of: lobbyScope,
              matching: find.byKey(Key('game-seat-pip-$seat')),
            ),
            findsOneWidget,
            reason: 'rule 5: pip for occupied seat $seat must be on screen',
          );
        }
        for (final int seat in <int>[2, 3]) {
          expect(
            find.descendant(
              of: lobbyScope,
              matching: find.byKey(Key('game-seat-pip-$seat')),
            ),
            findsNothing,
            reason:
                'rule 5: pip for unoccupied seat $seat must not be on '
                'screen; the pip strip shows only occupied seats now',
          );
        }
      },
    );
  });

  // ===========================================================================
  // Rule 7: 360x800, en/ar, text scale 1.0/1.3, four seats plus the
  // rematch-waiting line, no "overflowed" FlutterError.
  // ===========================================================================
  group('C-254 rule 7: no overflow at 360x800', () {
    for (final Locale locale in <Locale>[
      const Locale('en'),
      const Locale('ar'),
    ]) {
      for (final double textScale in <double>[1.0, 1.3]) {
        testWidgets(
          '360x800, ${locale.languageCode}, text scale ${textScale}x: four '
          'seats plus lobby-rematch-waiting does not overflow',
          (tester) async {
            await tester.binding.setSurfaceSize(const Size(360, 800));
            addTearDown(() => tester.binding.setSurfaceSize(null));

            final List<FlutterErrorDetails> captured = <FlutterErrorDetails>[];
            final void Function(FlutterErrorDetails)? previous =
                FlutterError.onError;
            FlutterError.onError = captured.add;
            try {
              final RoomController controller = await _mountConnectedLobby(
                tester,
                mySeat: 0,
                hostSeat: 0,
                players: 4,
                seats: <Map<String, Object?>>[
                  _seatJson(0, name: 'Priya', connected: true),
                  _seatJson(1, name: 'Karim', connected: true),
                  _seatJson(2, name: 'Lina', connected: true),
                  _seatJson(3, name: 'Omar', connected: false),
                ],
                rematch: <String, Object?>{
                  'by': 1,
                  'ready': <int>[0],
                },
                locale: locale,
                textScale: textScale,
              );
              await tester.pump();

              // This capture's own overflow coverage is only meaningful
              // once the seat-card grid (not the bare list) is actually on
              // screen with all four seats present: assert the fixture
              // reached that state before trusting "no overflow" below.
              expect(
                controller.room!.seats.length,
                4,
                reason: 'fixture: all four seats must be occupied',
              );
              for (final int seat in <int>[0, 1, 2, 3]) {
                expect(
                  find.byKey(Key('lobby-seat-$seat-token')),
                  findsOneWidget,
                  reason:
                      'rule 7 fixture: expected the seat-card grid '
                      '(lobby-seat-$seat-token) on screen before trusting '
                      'the overflow check below, at 360x800, '
                      '${locale.languageCode}, text scale ${textScale}x',
                );
              }
              expect(
                find.byKey(const Key('lobby-rematch-waiting')),
                findsOneWidget,
                reason:
                    'rule 7 fixture: expected lobby-rematch-waiting on '
                    'screen alongside the four seat cards',
              );
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
                  'rule 7: the connected lobby at 360x800, '
                  '${locale.languageCode}, text scale ${textScale}x, with '
                  'four seats and the rematch-waiting line, must not '
                  'report a RenderFlex overflow; got $overflows',
            );
          },
        );
      }
    }
  });
}
