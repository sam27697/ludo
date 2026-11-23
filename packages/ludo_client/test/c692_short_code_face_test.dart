// C-692t: the room code on the die face clears the pips (X218).
//
// A real LobbyScreen over a real RoomController on FakeTransport, hosting a
// room whose code the server made 1 to 6 symbols long. Pinned, en and ar:
//   - the painted code rect lies inside the DieMark rect
//   - the painted code rect intersects none of the four pips
//   - a 1 or 2 symbol code is set at a font size >= the six-symbol code
//
// Pip geometry: the pips are painted by a private CustomPainter and are not
// widgets, so their circles are computed here from the die's laid-out size the
// way the painter does (die_mark.dart `_DieMarkPainter`): with s the die side,
// centre (s/2, s/2), pip centres at the centre +-0.22 s on both axes, pip
// radius 0.095 s, plus half the edge stroke max(1, 0.014 s). A pip counts as
// hit when the code rect comes within that radius of its centre (circle
// against rectangle, not the circle's bounding square).
// The code rect is the layout box of the Text widget, mapped into the die's
// own (unrotated) coordinates, so the die's tilt does not widen it.
//
// Replay: flutter test test/c692_short_code_face_test.dart --plain-name '<id>'

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
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

int _serverIdSeq = 0;
String _frame(String type, Map<String, Object?> data, {String? re}) {
  _serverIdSeq += 1;
  return jsonEncode(<String, Object?>{
    'v': 1,
    't': type,
    'id': 'c692f-srv-${_serverIdSeq.toString().padLeft(6, '0')}',
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

class _Face {
  _Face({
    required this.id,
    required this.code,
    required this.locale,
    required this.die,
    required this.code_,
    required this.fontSize,
  });

  final String id;
  final String code;
  final String locale;

  /// The DieMark's own box, die-local coordinates (origin at its corner).
  final Rect die;

  /// The code Text's layout box in die-local coordinates.
  final Rect code_;
  final double? fontSize;

  String get why =>
      'scenario "$id" (code "$code", locale $locale, die $die, code rect '
      '$code_, font size $fontSize). reproduce: flutter test '
      "test/c692_short_code_face_test.dart --plain-name '$id'";

  /// Indices of the pips whose painted circle the code rect reaches.
  List<int> get pipsHit {
    final double s = die.shortestSide;
    final double r = s * 0.095 + math.max(1.0, s * 0.014) / 2;
    final Offset c = Offset(s / 2, s / 2);
    final double off = s * 0.22;
    final List<Offset> spots = <Offset>[
      c + Offset(-off, -off),
      c + Offset(off, -off),
      c + Offset(-off, off),
      c + Offset(off, off),
    ];
    return <int>[
      for (int i = 0; i < 4; i += 1)
        if ((spots[i] -
                    Offset(
                      spots[i].dx.clamp(code_.left, code_.right),
                      spots[i].dy.clamp(code_.top, code_.bottom),
                    ))
                .distance <
            r)
          i,
    ];
  }

  static Future<_Face> open(
    WidgetTester tester,
    String code,
    String lang,
  ) async {
    final String id = 'face.$lang.$code';
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final FakeTransport transport = FakeTransport();
    final RoomController controller = RoomController(
      serverUrl: Uri.parse('wss://c692-face.invalid/ws'),
      connect: (Uri url) async => transport as WireTransport,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        locale: Locale(lang),
        theme: buildAppTheme(),
        supportedLocales: appSupportedLocales,
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: LobbyScreen(
          key: ValueKey<String>(id),
          controller: controller,
          action: LobbyAction.create,
          playerName: 'Sam',
          players: 4,
          shareText: (String text) async {},
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
        'seat_token': 'tok-c692-f',
      }),
    );
    transport.pushText(_frame('room', _room(code), re: requestId));
    await tester.pump();
    await tester.pump();
    expect(
      controller.phase,
      RoomPhase.connected,
      reason: 'fixture: expected a connected lobby. scenario "$id"',
    );
    await tester.pump(const Duration(milliseconds: 600));
    final Finder text = find.byKey(_codeKey);
    final Finder dieFinder = find.ancestor(
      of: text,
      matching: find.byType(DieMark),
    );
    expect(
      dieFinder,
      findsOneWidget,
      reason: 'fixture: expected the code on one DieMark. scenario "$id"',
    );
    final RenderBox dieBox = tester.renderObject<RenderBox>(
      find.descendant(of: dieFinder, matching: find.byType(CustomPaint)).first,
    );
    final RenderBox textBox = tester.renderObject<RenderBox>(text);
    final Rect local = MatrixUtils.transformRect(
      textBox.getTransformTo(dieBox),
      Offset.zero & textBox.size,
    );
    return _Face(
      id: id,
      code: code,
      locale: lang,
      die: Offset.zero & dieBox.size,
      code_: local,
      fontSize: tester.widget<Text>(text).style?.fontSize,
    );
  }
}

void main() {
  const List<String> codes = <String>['Z', 'Z7', 'Z7K', 'Z7KM', 'K7M2QP'];

  for (final String lang in <String>['en', 'ar']) {
    group('$lang: the code on the die face', () {
      for (final String code in codes) {
        testWidgets('code "$code" is inside the die', (tester) async {
          final _Face f = await _Face.open(tester, code, lang);
          expect(
            f.die.contains(f.code_.topLeft) &&
                f.die.contains(f.code_.bottomRight),
            isTrue,
            reason:
                'expected the painted code rect ${f.code_} inside the die '
                '${f.die}. ${f.why}',
          );
        });

        testWidgets('code "$code" touches no pip', (tester) async {
          final _Face f = await _Face.open(tester, code, lang);
          expect(
            f.pipsHit,
            isEmpty,
            reason:
                'expected the code rect ${f.code_} clear of all four pips '
                '(0 top-start, 1 top-end, 2 bottom-start, 3 bottom-end), '
                'it reaches ${f.pipsHit}. ${f.why}',
          );
        });
      }

      for (final String code in <String>['Z', 'Z7']) {
        testWidgets('code "$code" fills the pip-free centre', (tester) async {
          final _Face f = await _Face.open(tester, code, lang);
          final double ratio = f.code_.height / f.die.shortestSide;
          // ignore: avoid_print
          print('height ratio ${f.id}: ${ratio.toStringAsFixed(4)}');
          expect(
            ratio >= 0.26,
            isTrue,
            reason:
                'expected the painted code height >= 0.26 x the die side '
                '(${f.die.shortestSide}), measured ${f.code_.height} = '
                '${ratio.toStringAsFixed(4)}. ${f.why}',
          );
          expect(
            f.pipsHit,
            isEmpty,
            reason:
                'expected the enlarged code rect ${f.code_} to touch no pip, '
                'it reaches ${f.pipsHit}. ${f.why}',
          );
        });

        testWidgets('code "$code" is not set smaller than six symbols', (
          tester,
        ) async {
          final _Face six = await _Face.open(tester, 'K7M2QP', lang);
          final _Face s = await _Face.open(tester, code, lang);
          expect(
            s.fontSize != null &&
                six.fontSize != null &&
                s.fontSize! >= six.fontSize!,
            isTrue,
            reason:
                'expected the font size of "$code" (${s.fontSize}) >= the '
                'six-symbol size (${six.fontSize}). ${s.why}',
          );
        });
      }
    });
  }
}
