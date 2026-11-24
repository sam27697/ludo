// C-686t RETURN 2, T7: the refusal mark.
//
// A refusal ("the host or the strike ladder said no to this player") wears the
// red refusal mark: an Icon of Icons.cancel_rounded inside a RefusalNoticeMark,
// and never the neutral Icons.info_outline_rounded in the same card (P2, P9,
// P10, order 686 RETURN 2 items L4 and T7).
//
// Rows:
//   Home, en and ar: the not-joined notice (knock_failed rejected) and the
//     kicked notice (kicked), both without a ban object, card key home-notice.
//   Lobby error card, en and ar: errorCode KICKED, KNOCK_REFUSED, CODE_BANNED,
//     TOO_MANY_KNOCKS, card key lobby-error-card.
// The neutral codes (NO_SUCH_ROOM, ROOM_FULL, ROOM_STARTED, RATE_LIMITED,
// transport) are deliberately not asserted on here.
//
// Replay: flutter test test/c686_refusal_mark_test.dart --plain-name '<id>'

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/code_ban_notice.dart' show RefusalNoticeMark;
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';
import 'support/home_flow.dart';

const Key _codeKey = Key('room-code-field');
const Key _joinKey = Key('join-room-button');
const String _code = 'K7M2QP';
const String _install = 'Aa0_-Aa0_-Aa0_-Aa0_-Aa0_-Aa0_-Zz';

int _serverIdSeq = 0;
String _frame(String type, Map<String, Object?> data, {String? re}) {
  _serverIdSeq += 1;
  return jsonEncode(<String, Object?>{
    'v': 1,
    't': type,
    'id': 'c686m-srv-${_serverIdSeq.toString().padLeft(6, '0')}',
    're': ?re,
    'd': data,
  });
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;
String _typeOf(String raw) => _decode(raw)['t']! as String;

Map<String, Object?> _room(int seq) => <String, Object?>{
  'code': _code,
  'state': 'LOBBY',
  'host_seat': 0,
  'players': 4,
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
    for (int i = 0; i < 2; i += 1)
      <String, Object?>{
        'seat': i,
        'name': i == 0 ? 'Sam' : 'Me',
        'connected': true,
        'tokens': const <int>[-1, -1, -1, -1],
        'client_seed': null,
        'seed_origin': null,
        'via': i == 0 ? 'host' : 'code',
      },
  ],
  'turn': null,
  'winner': null,
  'seq': seq,
  'link_id': 't5k2q9a-x7m3pd',
  'guest_approval': false,
  'knocks': const <Object?>[],
};

const List<LocalizationsDelegate<dynamic>> _delegates =
    <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ];

/// What a card holds, as a sentence for a failure message.
String _marks(WidgetTester tester, Finder card) {
  final bool mark = find
      .descendant(of: card, matching: find.byType(RefusalNoticeMark))
      .evaluate()
      .isNotEmpty;
  final List<String> icons = <String>[
    for (final Element e
        in find.descendant(of: card, matching: find.byType(Icon)).evaluate())
      '${(e.widget as Icon).icon}',
  ];
  return 'RefusalNoticeMark present=$mark, icons=$icons';
}

void _expectRefusalMark(
  WidgetTester tester,
  Finder card, {
  required String scenario,
  required String replay,
}) {
  expect(
    card,
    findsOneWidget,
    reason: 'expected exactly one card for "$scenario". reproduce: $replay',
  );
  final Finder mark = find.descendant(
    of: card,
    matching: find.byType(RefusalNoticeMark),
  );
  expect(
    mark,
    findsOneWidget,
    reason:
        'expected one RefusalNoticeMark in the card for "$scenario"; found '
        '${_marks(tester, card)}. reproduce: $replay',
  );
  expect(
    find.descendant(
      of: mark,
      matching: find.byWidgetPredicate(
        (Widget w) => w is Icon && w.icon == Icons.cancel_rounded,
      ),
    ),
    findsOneWidget,
    reason:
        'expected Icons.cancel_rounded inside the RefusalNoticeMark for '
        '"$scenario"; found ${_marks(tester, card)}. reproduce: $replay',
  );
  expect(
    find.descendant(
      of: card,
      matching: find.byWidgetPredicate(
        (Widget w) => w is Icon && w.icon == Icons.info_outline_rounded,
      ),
    ),
    findsNothing,
    reason:
        'expected no Icons.info_outline_rounded in the same card for '
        '"$scenario"; found ${_marks(tester, card)}. reproduce: $replay',
  );
}

// ---------------------------------------------------------------------------
// Home: the not-joined and kicked notices.
// ---------------------------------------------------------------------------

class _Home {
  _Home(this.id, this.tester);

  final String id;
  final WidgetTester tester;
  final List<FakeTransport> transports = <FakeTransport>[];

  String get replay =>
      "flutter test test/c686_refusal_mark_test.dart --plain-name '$id'";

  FakeTransport get transport => transports.last;

  int get joinCount => transports
      .expand((FakeTransport t) => t.sentRaw)
      .where((String r) => _typeOf(r) == 'join_room')
      .length;

  String get joinId =>
      _decode(
            transport.sentRaw.lastWhere(
              (String r) => _typeOf(r) == 'join_room',
            ),
          )['id']!
          as String;

  static Future<_Home> open(
    WidgetTester tester,
    String id,
    Locale locale,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'install_id': _install,
    });
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final _Home h = _Home(id, tester);
    final List<FakeTransport> queue = <FakeTransport>[
      for (int i = 0; i < 3; i += 1) FakeTransport(),
    ];
    int next = 0;
    RoomController factory() => RoomController(
      serverUrl: Uri.parse('wss://c686-mark.invalid/ws'),
      connect: (Uri url) async {
        final FakeTransport t = queue[next];
        next += 1;
        h.transports.add(t);
        return t as WireTransport;
      },
      autoReconnectDelays: const <Duration>[],
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        supportedLocales: appSupportedLocales,
        localizationsDelegates: _delegates,
        home: HomeScreen(
          key: ValueKey<String>(id),
          onToggleLocale: () {},
          controllerFactory: factory,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    // Order 701 (X226): a join needs a name; the default the old field held.
    await enterName(tester, oldDefaultName(locale.languageCode));
    return h;
  }

  Future<void> typeAndJoin() async {
    // Order 701: the code field is behind the join sheet's code tile.
    await openCodeEntry(tester);
    await tester.enterText(find.byKey(_codeKey), _code);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.ensureVisible(find.byKey(_joinKey));
    await tester.pump();
    await tester.tap(find.byKey(_joinKey));
    await tester.pump();
    await tester.pump();
    for (int i = 0; i < 30 && joinCount == 0; i += 1) {
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      joinCount,
      1,
      reason: 'fixture: expected one join_room to be sent. reproduce: $replay',
    );
  }

  Future<void> push(
    String type,
    Map<String, Object?> data, {
    bool reply = false,
  }) async {
    transport.pushText(_frame(type, data, re: reply ? joinId : null));
    await tester.pump();
    await tester.pump();
  }

  Future<void> waitForHomeNotice() async {
    for (int i = 0; i < 48; i += 1) {
      if (find.byKey(const Key('home-notice')).evaluate().isNotEmpty) {
        break;
      }
      await tester.pump(const Duration(milliseconds: 250));
    }
    await tester.pump(const Duration(milliseconds: 600));
  }

  Future<void> finish() => tester.pump(const Duration(seconds: 12));
}

// ---------------------------------------------------------------------------
// Lobby: the error card for a refused create.
// ---------------------------------------------------------------------------

Future<void> _lobbyErrorCard(
  WidgetTester tester,
  String id,
  Locale locale,
  String errorCode,
) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    'install_id': _install,
  });
  tester.view.physicalSize = const Size(800, 1800);
  tester.view.devicePixelRatio = 2;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final FakeTransport transport = FakeTransport();
  final RoomController controller = RoomController(
    serverUrl: Uri.parse('wss://c686-mark.invalid/ws'),
    connect: (Uri url) async => transport as WireTransport,
    autoReconnectDelays: const <Duration>[],
  );
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      supportedLocales: appSupportedLocales,
      localizationsDelegates: _delegates,
      home: LobbyScreen(
        controller: controller,
        action: LobbyAction.create,
        playerName: 'Sam',
        players: 4,
      ),
    ),
  );
  await tester.pump();
  final String replay =
      "flutter test test/c686_refusal_mark_test.dart --plain-name '$id'";
  expect(
    transport.sentRaw,
    isNotEmpty,
    reason:
        'fixture: expected the lobby to send its create request. '
        'reproduce: $replay',
  );
  final String requestId = _decode(transport.sentRaw.last)['id']! as String;
  transport.pushText(
    _frame('error', <String, Object?>{
      'code': errorCode,
      'message': 'refused',
    }, re: requestId),
  );
  await tester.pump();
  await tester.pump();
  expect(
    controller.errorCode,
    errorCode,
    reason:
        'fixture: expected controller.errorCode "$errorCode" after the error '
        'frame, got "${controller.errorCode}". reproduce: $replay',
  );
  _expectRefusalMark(
    tester,
    find.byKey(const Key('lobby-error-card')),
    scenario: 'lobby error card, $errorCode, ${locale.languageCode}',
    replay: replay,
  );
}

void main() {
  for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
    final String lc = locale.languageCode;

    group('home notices carry the refusal mark, $lc', () {
      testWidgets('not joined (knock_failed rejected, no ban)', (tester) async {
        final String id = 'home.notjoined.$lc';
        final _Home h = await _Home.open(tester, id, locale);
        await h.typeAndJoin();
        await h.push('knock_pending', <String, Object?>{
          'knock_id': 'kn-me',
          'expires_ms': 60000,
        }, reply: true);
        await h.push('knock_failed', <String, Object?>{
          'knock_id': 'kn-me',
          'outcome': 'rejected',
        });
        await h.waitForHomeNotice();
        _expectRefusalMark(
          tester,
          find.byKey(const Key('home-notice')),
          scenario: 'home not-joined notice, $lc',
          replay: h.replay,
        );
        await h.finish();
      });

      testWidgets('kicked (kicked, no ban)', (tester) async {
        final String id = 'home.kicked.$lc';
        final _Home h = await _Home.open(tester, id, locale);
        await h.typeAndJoin();
        await h.push('seat_assigned', <String, Object?>{
          'seat': 1,
          'seat_token': 'tok-c686-m',
        });
        await h.push('room', _room(5), reply: true);
        await tester.pump(const Duration(seconds: 1));
        await h.push('kicked', <String, Object?>{});
        await h.waitForHomeNotice();
        _expectRefusalMark(
          tester,
          find.byKey(const Key('home-notice')),
          scenario: 'home kicked notice, $lc',
          replay: h.replay,
        );
        await h.finish();
      });
    });

    group('lobby error card carries the refusal mark, $lc', () {
      for (final String code in const <String>[
        'KICKED',
        'KNOCK_REFUSED',
        'CODE_BANNED',
        'TOO_MANY_KNOCKS',
      ]) {
        testWidgets('errorCode $code', (tester) async {
          await _lobbyErrorCard(tester, 'lobby.$code.$lc', locale, code);
        });
      }
    });
  }
}
