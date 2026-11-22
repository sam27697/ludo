// C-686t: a short room code on the lobby, order 686 goal 2 (P8) and
// docs/PROTOCOL.md section 32 item 1.
//
// A real LobbyScreen over a real RoomController on FakeTransport, hosting a
// room whose code the server made 1 to 6 symbols long. What is pinned:
//   - the code is shown as is in `lobby-room-code`, on the die frame
//   - a code of 1 or 2 symbols has the same weight and the same type size as
//     a six-symbol one, sits centred in the same die frame, and the frame is
//     not narrower than it is for six symbols (it keeps its width)
//   - the share text and the copy action carry the code as is
//   - 320 dp at text scale 2.0, en and ar: no overflow
//
// Names assumed: none new (lobby-room-code, lobby-copy-code-button,
// lobby-share-button and LobbyScreen.shareText exist on the tree today).
//
// Replay: flutter test test/c686_lobby_code_test.dart --plain-name '<id>'

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/die_mark.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

const Key _codeKey = Key('lobby-room-code');
const Key _copyCodeKey = Key('lobby-copy-code-button');
const Key _shareKey = Key('lobby-share-button');

int _serverIdSeq = 0;
String _frame(String type, Map<String, Object?> data, {String? re}) {
  _serverIdSeq += 1;
  return jsonEncode(<String, Object?>{
    'v': 1,
    't': type,
    'id': 'c686l-srv-${_serverIdSeq.toString().padLeft(6, '0')}',
    're': ?re,
    'd': data,
  });
}

Map<String, Object?> _room(String code) => <String, Object?>{
  'code': code,
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
      'via': 'host',
    },
  ],
  'turn': null,
  'winner': null,
  'seq': 1,
  'link_id': 't5k2q9a-x7m3pd',
  'guest_approval': false,
  'knocks': const <Object?>[],
};

class _Lobby {
  _Lobby(this.id, this.code, this.tester, this.shared);

  final String id;
  final String code;
  final WidgetTester tester;
  final List<String> shared;

  String get why =>
      'scenario "$id" (room code "$code"). reproduce: flutter test '
      "test/c686_lobby_code_test.dart --plain-name '$id'";

  static Future<_Lobby> open(
    WidgetTester tester,
    String id,
    String code, {
    Locale locale = const Locale('en'),
    double width = 400,
    double height = 900,
    double textScale = 1.0,
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.physicalSize = Size(width * 2, height * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final FakeTransport transport = FakeTransport();
    final RoomController controller = RoomController(
      serverUrl: Uri.parse('wss://c686-lobby.invalid/ws'),
      connect: (Uri url) async => transport as WireTransport,
    );
    addTearDown(controller.dispose);
    final List<String> shared = <String>[];
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
        builder: (BuildContext context, Widget? child) {
          final MediaQueryData data = MediaQuery.of(context);
          return MediaQuery(
            data: data.copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          );
        },
        home: LobbyScreen(
          key: ValueKey<String>(id),
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
    expect(
      transport.sentRaw,
      isNotEmpty,
      reason: 'fixture: the lobby must send create_room. scenario "$id"',
    );
    final String requestId =
        (jsonDecode(transport.sentRaw.last) as Map<String, Object?>)['id']!
            as String;
    transport.pushText(
      _frame('seat_assigned', <String, Object?>{
        'seat': 0,
        'seat_token': 'tok-c686-l',
      }),
    );
    transport.pushText(_frame('room', _room(code), re: requestId));
    await tester.pump();
    await tester.pump();
    final _Lobby l = _Lobby(id, code, tester, shared);
    expect(
      controller.phase,
      RoomPhase.connected,
      reason: 'fixture: expected a connected lobby. ${l.why}',
    );
    return l;
  }

  Finder get codeText => find.byKey(_codeKey);

  Finder get frame =>
      find.ancestor(of: find.byKey(_codeKey), matching: find.byType(DieMark));

  Text get text => tester.widget<Text>(codeText);

  /// The type size actually painted: the scale a FittedBox applied is part of
  /// what a player sees.
  double get paintedHeight => tester.getSize(codeText).height;
}

void main() {
  const List<String> codes = <String>['0', 'Z', '10', 'K7M', 'K7M2QP'];

  group('the code is shown as is, on the die frame', () {
    for (final String code in codes) {
      testWidgets('code "$code" (${code.length} symbols)', (tester) async {
        final _Lobby l = await _Lobby.open(tester, 'shown.$code', code);
        expect(
          l.text.data,
          code,
          reason: 'expected lobby-room-code to read "$code". ${l.why}',
        );
        expect(
          l.frame,
          findsOneWidget,
          reason: 'expected the code on a DieMark frame. ${l.why}',
        );
      });
    }
  });

  group('a short code reads as a deliberate room code (P8)', () {
    testWidgets('1 and 2 symbols have the weight of 6', (tester) async {
      final _Lobby six = await _Lobby.open(tester, 'weight.six', 'K7M2QP');
      final FontWeight? sixWeight = six.text.style?.fontWeight;
      final double? sixSize = six.text.style?.fontSize;
      for (final String code in <String>['Z', 'Z7']) {
        final _Lobby s = await _Lobby.open(tester, 'weight.$code', code);
        expect(
          s.text.style?.fontWeight,
          sixWeight,
          reason:
              'expected the same font weight as a six-symbol code '
              '($sixWeight), saw ${s.text.style?.fontWeight}. ${s.why}',
        );
        expect(
          s.text.style?.fontSize,
          sixSize,
          reason:
              'expected the same font size as a six-symbol code ($sixSize), '
              'saw ${s.text.style?.fontSize}. ${s.why}',
        );
      }
    });

    testWidgets('1 and 2 symbols keep the die frame and sit centred in it', (
      tester,
    ) async {
      final _Lobby six = await _Lobby.open(tester, 'frame.six', 'K7M2QP');
      final Size sixFrame = tester.getSize(six.frame);
      for (final String code in <String>['Z', 'Z7']) {
        final _Lobby s = await _Lobby.open(tester, 'frame.$code', code);
        final Size frame = tester.getSize(s.frame);
        expect(
          frame.width,
          greaterThanOrEqualTo(sixFrame.width),
          reason:
              'expected the frame of "$code" not narrower than the six '
              'symbol frame ($sixFrame), saw $frame. ${s.why}',
        );
        final double dx =
            tester.getCenter(s.codeText).dx - tester.getCenter(s.frame).dx;
        expect(
          dx.abs(),
          lessThanOrEqualTo(1.5),
          reason:
              'expected "$code" horizontally centred in its frame, off by '
              '$dx dp. ${s.why}',
        );
        final double dy =
            tester.getCenter(s.codeText).dy - tester.getCenter(s.frame).dy;
        expect(
          dy.abs(),
          lessThanOrEqualTo(frame.height * 0.2),
          reason:
              'expected "$code" vertically on the die face, off by $dy dp '
              'in a frame $frame high. ${s.why}',
        );
      }
    });

    testWidgets('1 symbol is not smaller on screen than 6 symbols', (
      tester,
    ) async {
      final _Lobby six = await _Lobby.open(tester, 'size.six', 'K7M2QP');
      final double sixHeight = six.paintedHeight;
      final _Lobby one = await _Lobby.open(tester, 'size.one', 'Z');
      expect(
        one.paintedHeight,
        greaterThanOrEqualTo(sixHeight - 0.5),
        reason:
            'expected a one-symbol code at least as tall as six symbols '
            '($sixHeight dp), saw ${one.paintedHeight}. ${one.why}',
      );
    });
  });

  group('share text and copy carry the code as is', () {
    for (final String code in <String>['0', 'Z', 'Z7', 'K7M2QP']) {
      testWidgets('share text carries "$code"', (tester) async {
        final _Lobby l = await _Lobby.open(tester, 'share.$code', code);
        await tester.ensureVisible(find.byKey(_shareKey));
        await tester.pump();
        await tester.tap(find.byKey(_shareKey));
        await tester.pump();
        expect(
          l.shared,
          hasLength(1),
          reason: 'expected one share, saw ${l.shared}. ${l.why}',
        );
        expect(
          l.shared.single,
          contains(code),
          reason:
              'expected the share text to carry "$code", saw '
              '"${l.shared.single}". ${l.why}',
        );
      });

      testWidgets('copy action puts "$code" on the clipboard', (tester) async {
        final List<String?> copied = <String?>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (MethodCall call) async {
            if (call.method == 'Clipboard.setData') {
              copied.add(
                (call.arguments as Map<Object?, Object?>)['text'] as String?,
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
        final _Lobby l = await _Lobby.open(tester, 'copy.$code', code);
        await tester.ensureVisible(find.byKey(_copyCodeKey));
        await tester.pump();
        await tester.tap(find.byKey(_copyCodeKey));
        await tester.pump();
        await tester.pump(const Duration(seconds: 5));
        expect(
          copied,
          <String?>[code],
          reason:
              'expected the clipboard to receive exactly "$code", saw '
              '$copied. ${l.why}',
        );
      });
    }
  });

  group('320 dp at text scale 2.0', () {
    for (final String lang in <String>['en', 'ar']) {
      for (final String code in <String>['Z', 'Z7', 'K7M2QP']) {
        testWidgets('$lang code "$code": no overflow', (tester) async {
          final _Lobby l = await _Lobby.open(
            tester,
            'fit.$lang.$code',
            code,
            locale: Locale(lang),
            width: 320,
            height: 640,
            textScale: 2.0,
          );
          await tester.pump(const Duration(milliseconds: 600));
          expect(
            tester.takeException(),
            isNull,
            reason: 'expected no layout exception at 320 dp x2.0. ${l.why}',
          );
          final Rect rect = tester.getRect(l.codeText);
          expect(
            rect.left >= 0 && rect.right <= 320,
            isTrue,
            reason:
                'expected the code inside 0..320 dp, saw '
                '${rect.left}..${rect.right}. ${l.why}',
          );
          expect(l.text.data, code, reason: 'code unchanged. ${l.why}');
        });
      }
    }
  });
}
