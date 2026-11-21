// C-681t: the shared URL is built from the link id (order 681; section 31
// item 1). `kRoomLinkBase + snapshot.linkId` is what the lobby shares and
// copies; an old server that sends no `link_id` leaves linkId empty and the
// share falls back to the code link `kRoomLinkBase + code`, as before.
//
// Written from the order alone, against `RoomSnapshot.linkId` (a name that
// does not exist until order 681's lib lands; until then the lobby cases here
// are red on the link-id expectation and, if the snapshot parser ignores
// `link_id`, the whole file is merely red, not uncompilable, because the
// scenario JSON is built by hand and never names the new type).
//
// A real LobbyScreen over a real RoomController over FakeTransport, the road
// test/lobby_invite_share_test.dart takes. The injected `shareText` records
// the line; the clipboard channel is mocked for the copy button.
//
// Replay: flutter test test/c681_share_link_test.dart --plain-name '<id>'

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

const String _code = 'PLAY42';
const String _linkId = 't5k2q9a-x7m3pd';
const String _linkUrl = 'https://ludo.provefair.app/r/$_linkId';
const String _codeUrl = 'https://ludo.provefair.app/r/$_code';

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'c681-sl-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

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

Map<String, Object?> _roomJson({required bool withLinkId}) => <String, Object?>{
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
    <String, Object?>{
      'seat': 0,
      'name': 'Sam',
      'connected': true,
      'tokens': const <int>[-1, -1, -1, -1],
      'client_seed': null,
      'seed_origin': null,
      if (withLinkId) 'via': 'host',
    },
  ],
  'turn': null,
  'winner': null,
  'seq': 1,
  if (withLinkId) 'link_id': _linkId,
  if (withLinkId) 'guest_approval': false,
  if (withLinkId) 'knocks': const <Object?>[],
};

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];
  void enqueue(FakeTransport transport) => _queue.add(transport);
  Future<WireTransport> call(Uri url) async => _queue.removeAt(0);
}

Widget _harness(Widget child) => MaterialApp(
  locale: const Locale('en'),
  supportedLocales: appSupportedLocales,
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  home: child,
);

/// A connected host lobby. Returns what the share function received.
Future<List<String>> _mount(
  WidgetTester tester, {
  required bool withLinkId,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse('wss://c681-share.invalid/ws'),
    connect: connector.call,
  );
  addTearDown(controller.dispose);
  final List<String> shared = <String>[];
  await tester.pumpWidget(
    _harness(
      LobbyScreen(
        controller: controller,
        action: LobbyAction.create,
        playerName: 'Sam',
        players: 4,
        shareText: (String text) async {
          shared.add(text);
        },
      ),
    ),
  );
  await tester.pump();
  final String requestId =
      (jsonDecode(transport.sentRaw.last) as Map<String, Object?>)['id']!
          as String;
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': 0, 'seat_token': 'tok-c681-sl'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: requestId,
      data: _roomJson(withLinkId: withLinkId),
    ),
  );
  await tester.pump();
  await tester.pump();
  return shared;
}

String _why(String id, String wanted, Object? saw) =>
    "$id: expected $wanted; saw $saw. reproduce: flutter test "
    "test/c681_share_link_test.dart --plain-name '$id'";

void main() {
  testWidgets('share carries the link id URL once and not the code URL', (
    tester,
  ) async {
    final List<String> shared = await _mount(tester, withLinkId: true);
    await tester.tap(find.byKey(const Key('lobby-share-button')));
    expect(
      shared,
      hasLength(1),
      reason: _why('share.link', 'one share call', shared),
    );
    final String line = shared.single;
    expect(
      RegExp(RegExp.escape(_linkUrl)).allMatches(line).length,
      1,
      reason: _why('share.link', 'the link-id URL exactly once', line),
    );
    expect(
      line.contains(_codeUrl),
      isFalse,
      reason: _why(
        'share.link',
        'no code URL (a code is not a link now)',
        line,
      ),
    );
  });

  testWidgets('copy link puts the link id URL on the clipboard', (
    tester,
  ) async {
    final List<String> clip = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          clip.add(
            (call.arguments as Map<Object?, Object?>)['text']! as String,
          );
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
    await _mount(tester, withLinkId: true);
    await tester.tap(find.byKey(const Key('lobby-copy-link-button')));
    await tester.pump();
    expect(clip, <String>[
      _linkUrl,
    ], reason: _why('copy.link', '[$_linkUrl]', clip));
  });

  testWidgets('an old server without link_id shares the code link as before', (
    tester,
  ) async {
    final List<String> shared = await _mount(tester, withLinkId: false);
    await tester.tap(find.byKey(const Key('lobby-share-button')));
    expect(
      shared,
      hasLength(1),
      reason: _why('share.old', 'one share call', shared),
    );
    final String line = shared.single;
    expect(
      line.contains(_codeUrl),
      isTrue,
      reason: _why('share.old', 'the code URL $_codeUrl', line),
    );
  });

  testWidgets('an old server without link_id copies the code link as before', (
    tester,
  ) async {
    final List<String> clip = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          clip.add(
            (call.arguments as Map<Object?, Object?>)['text']! as String,
          );
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
    await _mount(tester, withLinkId: false);
    await tester.tap(find.byKey(const Key('lobby-copy-link-button')));
    await tester.pump();
    expect(clip, <String>[
      _codeUrl,
    ], reason: _why('copy.old', '[$_codeUrl]', clip));
  });
}
