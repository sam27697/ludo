// Conformance tests for the lobby's one-tap invite button, written from
// work/ludo/orders/229-one-tap-invite.md's "Goal" and "Decisions already
// made" sections (the frozen specification named by work/ludo/orders/
// 230-invite-tests.md), against no implementation of that order's changes
// to lib/src/lobby_screen.dart. LobbyScreen does not carry a `shareText`
// constructor parameter and has no `lobby-share-button` on the branch this
// file was written on: a second worker is implementing order 229, blind, on
// a separate branch, at the same time. This file is expected to fail to
// compile on integrate/run65, and that failure to compile is itself the
// required red result.
//
// LobbyScreen is driven the same way test/lobby_screen_test.dart drives it:
// a real RoomController over a FakeTransport (test/net/fake_transport.dart,
// read-only, not edited here), reaching RoomPhase.connected the same way
// that file does. The connector double and JSON/frame helpers below are
// copied from that file's own idiom rather than imported from it, for the
// same reason that file gives for not importing room_controller_test.dart's
// idiom: none of it is exported, and this order's file list does not permit
// editing lobby_screen_test.dart to export it.
//
// Ambiguities found while writing this file, reported rather than invented
// around (standing rule: "Ambiguity is reported, never invented around"):
//
//   1. "no dialog or intermediate step appears between the tap and the
//      shareText call ... before any further pump beyond the tap's own
//      frame" is read literally: the assertion that shareText was called
//      exactly once is made immediately after `await tester.tap(...)`,
//      with no `tester.pump()` call in between. This relies on Flutter's
//      own gesture arena resolving a lone tap recognizer synchronously
//      inside `TestGesture.up()`, which is what `tester.tap()` awaits, so
//      an onPressed callback (and whatever it calls synchronously, up to
//      its own first `await`) has already run by the time `tester.tap()`
//      returns. If a future implementation inserts a real pushed route
//      (a dialog, a bottom sheet) before calling shareText, that route's
//      build would need a pump to appear in the tree, so the accompanying
//      find.byType(Dialog)/find.byType(BottomSheet) checks here are a
//      best-effort second signal, not the primary proof; the call-count
//      check taken with zero intervening pumps is the primary proof of
//      "one tap, no intermediate step".
//
//   2. "the share line contains the link exactly once and the code" is
//      read as two checks: the full link string appears exactly once in
//      the share line, and the bare code string still appears in the line
//      with that one link occurrence removed (i.e. the code is not only
//      present because it happens to be a substring of the link that was
//      already counted).
//
//   3. Order 229 restyles the two copy buttons as TextButtons; order 230's
//      checklist asks only that they "still copy what they copied before",
//      not that a particular widget type back them. This file taps them
//      by key and asserts on clipboard/snackbar behaviour only, and never
//      casts the button found at 'lobby-copy-link-button' or
//      'lobby-copy-code-button' to a concrete button class, so a change of
//      button type alone cannot fail it.
//
//   4. Order 230's checklist covers only the injected `shareText` path.
//      The `shareText == null` fallback (share_plus over a real Android
//      intent) is out of scope here and is not exercised or mocked; every
//      LobbyScreen built in this file passes a non-null `shareText`.
//
//   5. The forbidden-words check (doctrine P7) is run as a pure string
//      check against the literal expected share lines below, not against
//      a mounted widget: doctrine P7 is a property of the string
//      loc.lobbyShareText produces, not of how LobbyScreen displays it.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://example.test/ws';
const String _testCode = 'PLAY42';
const String _testLink = 'https://ludo.provefair.app/r/PLAY42';

/// The exact English share line for code PLAY42, spelled out as a literal
/// copied from app_en.arb's lobbyShareText entry with {link} and {code}
/// substituted, so a wording change in the ARB fails this test rather than
/// being silently re-derived by calling loc.lobbyShareText in the
/// assertion itself.
const String _expectedShareTextEn =
    "Let's play Ludo! Join my room with this link: "
    'https://ludo.provefair.app/r/PLAY42 or type the code PLAY42 in Ludo '
    'RNG.';

/// The exact Arabic share line for code PLAY42, spelled out as a literal
/// copied from app_ar.arb's lobbyShareText entry the same way.
const String _expectedShareTextAr =
    'تعال نلعب لودو! ادخل غرفتي من هذا الرابط: '
    'https://ludo.provefair.app/r/PLAY42 أو اكتب الرمز PLAY42 في Ludo RNG.';

/// Doctrine P7's forbidden words, checked case-insensitively in both
/// locales' share lines.
const List<String> _forbiddenWordsCaseInsensitive = <String>[
  'provably fair',
  'absolute randomness',
  'bet',
  'wager',
  'odds',
];

/// Doctrine P7's forbidden Arabic words, checked only against the Arabic
/// share line.
const List<String> _forbiddenWordsArabic = <String>['رهان', 'مراهنة'];

// --- server-side id generation for pushed frames ---------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

// --- small JSON helpers, mirroring test/net/room_controller_test.dart ------

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
}) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': connected,
  'tokens': <int>[-1, -1, -1, -1],
  'client_seed': null,
  'seed_origin': null,
};

Map<String, Object?> _roomJson({
  String code = _testCode,
  String state = 'LOBBY',
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
  'seats':
      seats ??
      <Map<String, Object?>>[_seatJson(hostSeat, name: 'Sam', connected: true)],
  'turn': turn,
  'winner': winner,
  'seq': seq,
};

// --- a TransportConnector test double, copied from lobby_screen_test.dart's
// --- own idiom (itself copied from room_controller_test.dart's), rather
// --- than imported: neither file exports it, and neither is on this
// --- order's file list to modify. ------------------------------------------

/// Hands out queued [FakeTransport]s, one per call, in order.
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

/// Mounts [screen], waits for the request LobbyScreen's initState issues,
/// and returns the raw sent message's id so a reply can target it with `re`.
Future<String> _mountAndCaptureRequest(
  WidgetTester tester,
  Widget screen,
  FakeTransport transport, {
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(_harness(screen, locale: locale));
  await tester.pump();
  expect(
    transport.sentRaw,
    isNotEmpty,
    reason:
        'expected LobbyScreen.initState to have sent exactly one request '
        'to the transport by now (createRoom or joinRoom); sentRaw is '
        'empty',
  );
  return _idOf(transport.sentRaw.last);
}

Future<void> _resolveConnected(
  WidgetTester tester,
  FakeTransport transport,
  String requestId, {
  required int seatForThisClient,
  String code = _testCode,
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

/// Mounts a connected LobbyScreen for code [_testCode], as host (seat 0 of
/// 1) when [asHost] is true, or as a guest (seat 1 of 2, host seat 0)
/// otherwise, with [shareText] wired in as the injected share function.
/// Returns the controller so callers can dispose it.
Future<RoomController> _mountConnectedLobby(
  WidgetTester tester, {
  required bool asHost,
  required Future<void> Function(String text) shareText,
  Locale locale = const Locale('en'),
}) async {
  final connector = _Connector();
  final transport = FakeTransport();
  connector.enqueue(transport);
  final controller = _newController(connector);

  final Widget screen = asHost
      ? LobbyScreen(
          controller: controller,
          action: LobbyAction.create,
          playerName: 'Sam',
          players: 4,
          shareText: shareText,
        )
      : LobbyScreen(
          controller: controller,
          action: LobbyAction.join,
          code: _testCode,
          playerName: 'Riri',
          shareText: shareText,
        );

  final id = await _mountAndCaptureRequest(
    tester,
    screen,
    transport,
    locale: locale,
  );

  if (asHost) {
    await _resolveConnected(
      tester,
      transport,
      id,
      seatForThisClient: 0,
      hostSeat: 0,
      players: 4,
      seats: <Map<String, Object?>>[_seatJson(0, name: 'Sam')],
    );
  } else {
    await _resolveConnected(
      tester,
      transport,
      id,
      seatForThisClient: 1,
      hostSeat: 0,
      players: 4,
      seats: <Map<String, Object?>>[
        _seatJson(0, name: 'Sam'),
        _seatJson(1, name: 'Riri'),
      ],
    );
  }

  expect(
    controller.isHost,
    asHost,
    reason:
        'test setup: expected controller.isHost == $asHost for this '
        'scenario',
  );
  expect(controller.room?.code, _testCode);

  return controller;
}

void main() {
  // --- button presence, label, size, for host and guest, en and ar. ------
  group('lobby-share-button exists for host and guest, in en and ar', () {
    for (final asHost in <bool>[true, false]) {
      for (final locale in <Locale>[const Locale('en'), const Locale('ar')]) {
        testWidgets(
          '${asHost ? 'host' : 'guest'}, locale ${locale.languageCode}: '
          'lobby-share-button is present, labeled loc.lobbyShareButton, '
          'at least 48 high',
          (tester) async {
            final calls = <String>[];
            final controller = await _mountConnectedLobby(
              tester,
              asHost: asHost,
              shareText: (text) async {
                calls.add(text);
              },
              locale: locale,
            );
            addTearDown(controller.dispose);

            final finder = find.byKey(const Key('lobby-share-button'));
            expect(
              finder,
              findsOneWidget,
              reason:
                  'order 229: expected exactly one widget keyed '
                  'lobby-share-button for '
                  '${asHost ? 'a host' : 'a guest'} in locale '
                  '${locale.languageCode}; scenario code $_testCode',
            );

            final context = tester.element(find.byType(LobbyScreen));
            final loc = AppLocalizations.of(context);
            expect(
              find.descendant(
                of: finder,
                matching: find.text(loc.lobbyShareButton),
              ),
              findsOneWidget,
              reason:
                  'order 229: lobby-share-button must contain '
                  'Text(loc.lobbyShareButton), which reads '
                  '"${loc.lobbyShareButton}" in locale '
                  '${locale.languageCode}',
            );

            final size = tester.getSize(finder);
            expect(
              size.height,
              greaterThanOrEqualTo(48),
              reason:
                  'order 229: lobby-share-button must be at least 48 '
                  'logical pixels high; got ${size.height}',
            );
          },
        );
      }
    }
  });

  // --- tap sends the exact share line, for host and guest, en and ar. ----
  group('tapping lobby-share-button calls shareText exactly once with the '
      'exact loc.lobbyShareText(kRoomLinkBase + code, code) line', () {
    final cases = <({bool asHost, Locale locale, String expected})>[
      (
        asHost: true,
        locale: const Locale('en'),
        expected: _expectedShareTextEn,
      ),
      (
        asHost: true,
        locale: const Locale('ar'),
        expected: _expectedShareTextAr,
      ),
      (
        asHost: false,
        locale: const Locale('en'),
        expected: _expectedShareTextEn,
      ),
      (
        asHost: false,
        locale: const Locale('ar'),
        expected: _expectedShareTextAr,
      ),
    ];

    for (final c in cases) {
      testWidgets(
        '${c.asHost ? 'host' : 'guest'}, locale ${c.locale.languageCode}, '
        'code $_testCode',
        (tester) async {
          final calls = <String>[];
          final controller = await _mountConnectedLobby(
            tester,
            asHost: c.asHost,
            shareText: (text) async {
              calls.add(text);
            },
            locale: c.locale,
          );
          addTearDown(controller.dispose);

          await tester.tap(find.byKey(const Key('lobby-share-button')));

          expect(
            calls,
            hasLength(1),
            reason:
                'order 229/230: one tap on lobby-share-button must call '
                'the injected shareText exactly once; scenario '
                '${c.asHost ? 'host' : 'guest'}/${c.locale.languageCode}, '
                'code $_testCode; got ${calls.length} call(s): $calls',
          );
          expect(
            calls.single,
            c.expected,
            reason:
                'order 229: shareText must be called with exactly '
                'loc.lobbyShareText(kRoomLinkBase + code, code) for '
                'locale ${c.locale.languageCode} and code $_testCode, '
                'literally "${c.expected}"; got "${calls.single}". A '
                'mismatch here that is only a wording difference means '
                'app_${c.locale.languageCode}.arb\'s lobbyShareText '
                'changed without this test being told.',
          );

          final int linkOccurrences = calls.single.split(_testLink).length - 1;
          expect(
            linkOccurrences,
            1,
            reason:
                'order 229: the share line must contain the link '
                '"$_testLink" exactly once; found $linkOccurrences '
                'occurrence(s) in "${calls.single}"',
          );
          final String withoutLink = calls.single.replaceFirst(_testLink, '');
          expect(
            withoutLink.contains(_testCode),
            isTrue,
            reason:
                'order 229: the share line must contain the bare code '
                '"$_testCode" outside of the link occurrence, not only '
                'as a substring of the link; with the link removed once '
                'the remaining text is "$withoutLink"',
          );

          await tester.pump();
        },
      );
    }
  });

  // --- one tap: no intermediate step before shareText is called. ---------
  group('one tap: shareText is called within the tap, before any further '
      'pump', () {
    testWidgets(
      'host, en locale: no dialog or bottom sheet appears, and shareText '
      'has already been called by the time tester.tap returns, with zero '
      'additional pumps',
      (tester) async {
        final calls = <String>[];
        final controller = await _mountConnectedLobby(
          tester,
          asHost: true,
          shareText: (text) async {
            calls.add(text);
          },
        );
        addTearDown(controller.dispose);

        expect(
          calls,
          isEmpty,
          reason: 'test setup: shareText must not have been called yet',
        );
        expect(find.byType(Dialog), findsNothing);
        expect(find.byType(BottomSheet), findsNothing);

        await tester.tap(find.byKey(const Key('lobby-share-button')));

        expect(
          calls,
          hasLength(1),
          reason:
              'order 230: one tap must mean no dialog or intermediate step '
              'between the tap and the shareText call, the call happening '
              "within the same tap before any further pump beyond the "
              'tap\'s own frame; shareText had not been called by the '
              'moment tester.tap() returned, with no extra tester.pump() '
              'call made; got ${calls.length} call(s)',
        );
        expect(
          find.byType(Dialog),
          findsNothing,
          reason:
              'order 230: no Dialog may appear between the tap and the '
              'shareText call',
        );
        expect(
          find.byType(BottomSheet),
          findsNothing,
          reason:
              'order 230: no BottomSheet may appear between the tap and '
              'the shareText call',
        );

        await tester.pump();
      },
    );
  });

  // --- a throwing shareText falls back to the clipboard and a snackbar. ---
  group('shareText that throws falls back to the clipboard', () {
    testWidgets('host, en locale: the link lands on the clipboard, '
        'loc.lobbyLinkCopied shows, and the test itself does not record an '
        'uncaught exception', (tester) async {
      final clipboardCalls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            final args = call.arguments as Map<Object?, Object?>;
            clipboardCalls.add(args['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      final controller = await _mountConnectedLobby(
        tester,
        asHost: true,
        shareText: (text) async {
          throw Exception('share sheet unavailable: seed 230-throw');
        },
      );
      addTearDown(controller.dispose);

      await tester.tap(find.byKey(const Key('lobby-share-button')));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(
        tester.takeException(),
        isNull,
        reason:
            'order 229: "the error is never swallowed silently: '
            'debugPrint it" implies the widget itself catches the '
            'error from shareText; an uncaught exception recorded here '
            'means the implementation let a throwing shareText escape '
            'to the framework instead of falling back, for scenario '
            'host/en, code $_testCode',
      );
      expect(
        clipboardCalls,
        <String>[_testLink],
        reason:
            'order 229: a throwing shareText must fall back to copying '
            'exactly kRoomLinkBase + code == "$_testLink" to the '
            'clipboard; got $clipboardCalls',
      );

      final context = tester.element(find.byType(LobbyScreen));
      final loc = AppLocalizations.of(context);
      expect(
        find.widgetWithText(SnackBar, loc.lobbyLinkCopied),
        findsOneWidget,
        reason:
            'order 229: after the clipboard fallback, a SnackBar '
            'containing Text(loc.lobbyLinkCopied) must show, the same '
            'as the existing copy buttons already show',
      );
    });
  });

  // --- layout: the invite button sits above the copy buttons; the copy --
  // --- buttons still do what they did before. -----------------------------
  group('lobby-share-button sits above the copy buttons, which still copy '
      'what they copied before', () {
    testWidgets('host, en locale, code $_testCode', (tester) async {
      final clipboardCalls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            final args = call.arguments as Map<Object?, Object?>;
            clipboardCalls.add(args['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      final controller = await _mountConnectedLobby(
        tester,
        asHost: true,
        shareText: (text) async {},
      );
      addTearDown(controller.dispose);

      final shareTop = tester.getTopLeft(
        find.byKey(const Key('lobby-share-button')),
      );
      final copyLinkTop = tester.getTopLeft(
        find.byKey(const Key('lobby-copy-link-button')),
      );
      final copyCodeTop = tester.getTopLeft(
        find.byKey(const Key('lobby-copy-code-button')),
      );
      expect(
        shareTop.dy,
        lessThan(copyLinkTop.dy),
        reason:
            'order 229: lobby-share-button must sit above '
            'lobby-copy-link-button; got shareTop.dy=${shareTop.dy}, '
            'copyLinkTop.dy=${copyLinkTop.dy}',
      );
      expect(
        shareTop.dy,
        lessThan(copyCodeTop.dy),
        reason:
            'order 229: lobby-share-button must sit above '
            'lobby-copy-code-button; got shareTop.dy=${shareTop.dy}, '
            'copyCodeTop.dy=${copyCodeTop.dy}',
      );

      await tester.tap(find.byKey(const Key('lobby-copy-link-button')));
      await tester.pump();
      expect(
        clipboardCalls,
        <String>[_testLink],
        reason:
            'lobby-copy-link-button must still copy exactly '
            'kRoomLinkBase + code == "$_testLink"; got $clipboardCalls',
      );
      final context1 = tester.element(find.byType(LobbyScreen));
      final loc1 = AppLocalizations.of(context1);
      expect(
        find.widgetWithText(SnackBar, loc1.lobbyLinkCopied),
        findsOneWidget,
      );

      clipboardCalls.clear();
      await tester.tap(find.byKey(const Key('lobby-copy-code-button')));
      await tester.pump();
      expect(
        clipboardCalls,
        <String>[_testCode],
        reason:
            'lobby-copy-code-button must still copy exactly the bare '
            'code "$_testCode", not the link; got $clipboardCalls',
      );
      final context2 = tester.element(find.byType(LobbyScreen));
      final loc2 = AppLocalizations.of(context2);
      expect(
        find.widgetWithText(SnackBar, loc2.lobbyLinkCopied),
        findsOneWidget,
      );
    });
  });

  // --- doctrine P7: forbidden words on the share line, both locales. -----
  group('doctrine P7: the share line carries none of the forbidden words', () {
    test('English share line for code $_testCode has none of the forbidden '
        'English words', () {
      final lower = _expectedShareTextEn.toLowerCase();
      for (final word in _forbiddenWordsCaseInsensitive) {
        expect(
          lower.contains(word),
          isFalse,
          reason:
              'doctrine P7: the English share line must not contain '
              '"$word" (case-insensitive); share line was '
              '"$_expectedShareTextEn"',
        );
      }
    });

    test('Arabic share line for code $_testCode has none of the forbidden '
        'English words nor the forbidden Arabic words', () {
      final lower = _expectedShareTextAr.toLowerCase();
      for (final word in _forbiddenWordsCaseInsensitive) {
        expect(
          lower.contains(word),
          isFalse,
          reason:
              'doctrine P7: the Arabic share line must not contain '
              '"$word" (case-insensitive); share line was '
              '"$_expectedShareTextAr"',
        );
      }
      for (final word in _forbiddenWordsArabic) {
        expect(
          _expectedShareTextAr.contains(word),
          isFalse,
          reason:
              'doctrine P7: the Arabic share line must not contain '
              '"$word"; share line was "$_expectedShareTextAr"',
        );
      }
    });
  });
}
