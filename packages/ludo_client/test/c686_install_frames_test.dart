// C-686t: `install` on the wire, docs/PROTOCOL.md section 32 item 6.
//
// A real RoomController over FakeTransport (test/net/fake_transport.dart), the
// frames read back as the server would read them:
//   - `create_room` carries `install` (optional on the server, always sent
//     here), made and stored when none exists yet
//   - every `join_room` by `code` carries `install`: the join waits for the id
//     to be read or made, so it is never missing, for a stored id, for none
//     stored, and for one-symbol and six-symbol codes alike
//   - a `link` join is unchanged: it carries `link`, no `code`, and still
//     carries `install`
//   - the id is the same one on every frame of one phone
//
// Replay: flutter test test/c686_install_frames_test.dart --plain-name '<id>'

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:flutter_test/flutter_test.dart' as ft show testWidgets;
import 'package:ludo_client/src/install_id.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

const String _installA = 'Aa0_-Aa0_-Aa0_-Aa0_-Aa0_-Aa0_-Zz';
final RegExp _installShape = RegExp(r'^[A-Za-z0-9_-]{16,64}$');
const String _linkId = 't5k2q9a-x7m3pd';

Map<String, Object?> _decode(String raw) =>
    jsonDecode(raw) as Map<String, Object?>;
String _typeOf(String raw) => _decode(raw)['t']! as String;

final List<RoomController> _owned = <RoomController>[];

void testWidgets(
  String description,
  Future<void> Function(WidgetTester tester) body,
) {
  ft.testWidgets(description, (WidgetTester tester) async {
    _owned.clear();
    try {
      await body(tester);
    } finally {
      for (final RoomController c in _owned) {
        c.dispose();
      }
      _owned.clear();
      await tester.pump(const Duration(seconds: 11));
    }
  });
}

class _Scn {
  _Scn(this.id, this.tester, this.controller, this.transport);

  final String id;
  final WidgetTester tester;
  final RoomController controller;
  final FakeTransport transport;

  static Future<_Scn> open(
    WidgetTester tester,
    String id, {
    bool readInstallFirst = true,
  }) async {
    final FakeTransport transport = FakeTransport();
    final RoomController controller = RoomController(
      serverUrl: Uri.parse('wss://c686-install.invalid/ws'),
      connect: (Uri url) async => transport as WireTransport,
    );
    _owned.add(controller);
    if (readInstallFirst) {
      await tester.runAsync(installId);
    }
    return _Scn(id, tester, controller, transport);
  }

  String get why =>
      '$id: sent so far: ${transport.sentRaw}. reproduce: flutter test '
      "test/c686_install_frames_test.dart --plain-name '$id'";

  Future<void> settle() async {
    for (int i = 0; i < 5; i += 1) {
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump();
    }
  }

  Map<String, Object?> sentData(String type) {
    final List<String> hits = transport.sentRaw
        .where((String raw) => _typeOf(raw) == type)
        .toList();
    expect(
      hits,
      hasLength(1),
      reason: 'expected exactly one `$type` frame. $why',
    );
    return _decode(hits.single)['d']! as Map<String, Object?>;
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'install_id': _installA,
    });
  });

  group('create_room', () {
    testWidgets('create_room carries the stored install', (tester) async {
      final _Scn s = await _Scn.open(tester, 'create.stored');
      unawaited(s.controller.createRoom(name: 'Sam', players: 4));
      await s.settle();
      final Map<String, Object?> d = s.sentData('create_room');
      expect(
        d['install'],
        _installA,
        reason: 'expected the stored install in d=$d. ${s.why}',
      );
      expect(d['name'], 'Sam', reason: 'name kept. ${s.why}');
      expect(d['players'], 4, reason: 'players kept. ${s.why}');
    });

    testWidgets('create_room with no stored install carries a made one', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final _Scn s = await _Scn.open(
        tester,
        'create.made',
        readInstallFirst: false,
      );
      unawaited(s.controller.createRoom(name: 'Sam', players: 4));
      await s.settle();
      final Object? install = s.sentData('create_room')['install'];
      expect(
        install is String && _installShape.hasMatch(install),
        isTrue,
        reason:
            'expected install of 16..64 chars [A-Za-z0-9_-] on create_room '
            'with nothing stored; saw $install. ${s.why}',
      );
      final SharedPreferences prefs = await tester.runAsync(
        SharedPreferences.getInstance,
      ) as SharedPreferences;
      expect(
        prefs.getString('install_id'),
        install,
        reason: 'the install sent must be the one stored. ${s.why}',
      );
    });
  });

  group('join_room by code', () {
    for (final String code in <String>['0', 'Z', '10', 'K7M', 'K7M2QP']) {
      testWidgets('code "$code" carries install, and no link', (tester) async {
        final _Scn s = await _Scn.open(tester, 'join.code.$code');
        unawaited(s.controller.joinRoom(code: code, name: 'Bob'));
        await s.settle();
        final Map<String, Object?> d = s.sentData('join_room');
        expect(
          d['code'],
          code,
          reason: 'expected code "$code", d=$d. ${s.why}',
        );
        expect(
          d['install'],
          _installA,
          reason: 'expected the stored install, d=$d. ${s.why}',
        );
        expect(
          d.containsKey('link'),
          isFalse,
          reason: 'a code join must not carry a link, d=$d. ${s.why}',
        );
      });
    }

    testWidgets(
      'a code join made before the install id was read still carries one',
      (tester) async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final _Scn s = await _Scn.open(
          tester,
          'join.code.early',
          readInstallFirst: false,
        );
        unawaited(s.controller.joinRoom(code: 'Q', name: 'Bob'));
        await s.settle();
        final Map<String, Object?> d = s.sentData('join_room');
        final Object? install = d['install'];
        expect(
          install is String && _installShape.hasMatch(install),
          isTrue,
          reason:
              'expected a code join to wait for the install id and carry '
              'it; saw $install in d=$d. ${s.why}',
        );
      },
    );

    testWidgets('the same install rides on create and on a code join', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final _Scn a = await _Scn.open(
        tester,
        'same.create',
        readInstallFirst: false,
      );
      unawaited(a.controller.createRoom(name: 'Sam', players: 4));
      await a.settle();
      final Object? first = a.sentData('create_room')['install'];
      final _Scn b = await _Scn.open(tester, 'same.join');
      unawaited(b.controller.joinRoom(code: 'Z', name: 'Bob'));
      await b.settle();
      expect(
        b.sentData('join_room')['install'],
        first,
        reason:
            'expected one install for one phone; create sent $first. '
            '${a.why} / ${b.why}',
      );
    });
  });

  group('join_room by link is unchanged', () {
    testWidgets('a link join carries link and install, never a code', (
      tester,
    ) async {
      final _Scn s = await _Scn.open(tester, 'join.link');
      unawaited(s.controller.joinByLink(link: _linkId, name: 'Bob'));
      await s.settle();
      final Map<String, Object?> d = s.sentData('join_room');
      expect(d['link'], _linkId, reason: 'expected the link, d=$d. ${s.why}');
      expect(
        d.containsKey('code'),
        isFalse,
        reason: 'a link join must not carry a code, d=$d. ${s.why}',
      );
      expect(
        d['install'],
        _installA,
        reason: 'a link join keeps carrying install, d=$d. ${s.why}',
      );
    });
  });
}
