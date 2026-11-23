// C-697t: the host keeps the approval switch while knocks are open
// (order 696/697, ruling X216, doctrines P3 and P5).
//
// Switching guest approval off while knocks are open seats the knockers in
// arrival order (docs/PROTOCOL.md set_guest_approval), so the switch is the
// one-tap "let them all in" and must be on screen, in reach, while knocks wait.
//
// Rows: knocks {1,2,3} x seated {2,4} x size {320x640, 393x851} x locale
// {en, ar}, host lobby, text scale 1.0. Each row asserts:
//   1. exactly one ApprovalSwitch in the tree, fully inside the viewport
//      without scrolling, its switch target (key approval-switch) at least
//      48x48 dp, its rect intersecting no knock-card-*, no lobby-seat-* and
//      not the Start control;
//   2. a tap at the centre of the switch (the hit test reaches it) sends one
//      set_guest_approval whose enabled is the negation of the room's
//      guest_approval.
// Plus: a guest lobby with knocks in the snapshot shows no ApprovalSwitch; a
// host lobby with 0 knocks shows exactly one ApprovalSwitch.
//
// A real RoomController over FakeTransport, a real LobbyScreen. One test per
// row; the row id is the --plain-name needle.
//
// Replay: flutter test test/c697_knock_open_switch_test.dart \
//   --plain-name '<row id>'
// Every failure names the row, the widget, the rects and the viewport.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:flutter_test/flutter_test.dart' as ft show testWidgets;
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/install_id.dart';
import 'package:ludo_client/src/knock_bar.dart' show ApprovalSwitch;
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://c697-knock-switch.invalid/ws';
const String _code = 'K7M2QP';
const String _linkId = 't5k2q9a-x7m3pd';
const String _token = 'tok-c697-001';

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'c697-srv-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;
String _typeOf(String raw) => _decode(raw)['t']! as String;
Map<String, Object?> _dataOf(String raw) =>
    (_decode(raw)['d'] ?? <String, Object?>{}) as Map<String, Object?>;

String _frame(String type, Map<String, Object?> data, {String? re}) =>
    jsonEncode(<String, Object?>{
      'v': 1,
      't': type,
      'id': _nextServerId(),
      're': ?re,
      'd': data,
    });

const List<String> _seatNames = <String>['Sam', 'Abdulrahman', 'Bea', 'Cat'];
const List<String> _knockNames = <String>[
  'Fatima Al Mansoori',
  'Zed',
  'Mohammed Alhaddad',
];

Map<String, Object?> _roomJson({
  required int seated,
  required int knocks,
  required bool approval,
}) => <String, Object?>{
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
    for (int i = 0; i < seated; i += 1)
      <String, Object?>{
        'seat': i,
        'name': _seatNames[i],
        'connected': true,
        'tokens': const <int>[-1, -1, -1, -1],
        'client_seed': null,
        'seed_origin': null,
        'via': i == 0 ? 'host' : 'link',
      },
  ],
  'turn': null,
  'winner': null,
  'seq': 10,
  'link_id': _linkId,
  'guest_approval': approval,
  'knocks': <Map<String, Object?>>[
    for (int i = 0; i < knocks; i += 1)
      <String, Object?>{
        'knock_id': 'kn-${i + 1}',
        'name': _knockNames[i],
        'expires_ms': 60000,
      },
  ],
};

class _Silent implements FeedbackService {
  @override
  void play(FeedbackCue cue) {}
}

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];
  void enqueue(FakeTransport t) => _queue.add(t);
  Future<WireTransport> call(Uri url) async {
    if (_queue.isEmpty) {
      throw StateError('_Connector: nothing queued');
    }
    return _queue.removeAt(0);
  }
}

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

class _Row {
  const _Row({
    required this.knocks,
    required this.seated,
    required this.width,
    required this.height,
    required this.locale,
    required this.approval,
    this.host = true,
  });

  final int knocks;
  final int seated;
  final double width;
  final double height;
  final String locale;
  final bool approval;
  final bool host;

  String get id =>
      '${host ? 'host' : 'guest'}.k$knocks.seated$seated.'
      '${width.toInt()}x${height.toInt()}.$locale.approval$approval';

  String get why =>
      'row "$id". reproduce: flutter test '
      "test/c697_knock_open_switch_test.dart --plain-name '$id'";
}

class _Mounted {
  _Mounted(this.row, this.transport);
  final _Row row;
  final FakeTransport transport;

  List<Map<String, Object?>> sent(String type) => <Map<String, Object?>>[
    for (final String raw in transport.sentRaw)
      if (_typeOf(raw) == type) _dataOf(raw),
  ];
}

Future<_Mounted> _mount(WidgetTester tester, _Row row) async {
  tester.view.physicalSize = Size(row.width * 2, row.height * 2);
  tester.view.devicePixelRatio = 2;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
    autoReconnectDelays: const <Duration>[],
  );
  _owned.add(controller);
  await tester.pumpWidget(
    MaterialApp(
      locale: Locale(row.locale),
      supportedLocales: appSupportedLocales,
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: FeedbackScope(
        settings: FeedbackSettings.forTest(),
        service: _Silent(),
        child: LobbyScreen(
          controller: controller,
          action: row.host ? LobbyAction.create : LobbyAction.join,
          code: row.host ? null : _code,
          playerName: row.host ? 'Sam' : 'Bob',
          players: 4,
        ),
      ),
    ),
  );
  await tester.pump();
  final String reqId = _decode(transport.sentRaw.last)['id']! as String;
  transport.pushText(
    _frame('seat_assigned', <String, Object?>{
      'seat': row.host ? 0 : 1,
      'seat_token': _token,
    }),
  );
  transport.pushText(
    _frame(
      'room',
      _roomJson(seated: row.seated, knocks: row.knocks, approval: row.approval),
      re: reqId,
    ),
  );
  await tester.pump();
  await tester.pump();
  expect(
    controller.phase,
    RoomPhase.connected,
    reason: 'fixture: expected connected. ${row.why}',
  );
  return _Mounted(row, transport);
}

Finder _k(String key) => find.byKey(Key(key));

String _r(Rect r) =>
    'L${r.left.toStringAsFixed(1)} T${r.top.toStringAsFixed(1)} '
    'R${r.right.toStringAsFixed(1)} B${r.bottom.toStringAsFixed(1)}';

bool _inside(Rect inner, Rect outer) =>
    inner.left >= outer.left - 0.01 &&
    inner.top >= outer.top - 0.01 &&
    inner.right <= outer.right + 0.01 &&
    inner.bottom <= outer.bottom + 0.01;

Finder _start() {
  final Finder plain = _k('lobby-start-button');
  final Finder present = _k('lobby-start-with-present-button');
  return plain.evaluate().isNotEmpty ? plain : present;
}

/// Item 1 and item 2 as a list of violations. Item 2 runs only when item 1
/// found exactly one switch whose centre lies in the viewport.
Future<List<String>> _violations(WidgetTester tester, _Mounted m) async {
  final _Row row = m.row;
  final List<String> bad = <String>[];
  final Rect view = Offset.zero & Size(row.width, row.height);
  final String vp = 'viewport ${_r(view)}';

  final Finder sw = find.byType(ApprovalSwitch);
  final int count = sw.evaluate().length;
  if (count != 1) {
    bad.add(
      'ApprovalSwitch: expected exactly 1 in the tree, found $count. $vp',
    );
    return bad;
  }
  final Rect swRect = tester.getRect(sw);
  if (!_inside(swRect, view)) {
    bad.add(
      'ApprovalSwitch: expected fully inside the viewport without scrolling, '
      'saw ${_r(swRect)}. $vp',
    );
  }
  final Finder target = find.descendant(
    of: sw,
    matching: _k('approval-switch'),
  );
  if (target.evaluate().length != 1) {
    bad.add(
      'approval-switch target: expected 1 inside ApprovalSwitch, found '
      '${target.evaluate().length}. $vp',
    );
    return bad;
  }
  final Rect tRect = tester.getRect(target);
  if (tRect.width < 48 - 0.01 || tRect.height < 48 - 0.01) {
    bad.add(
      'approval-switch target: expected at least 48x48 dp, saw '
      '${tRect.width.toStringAsFixed(1)}x${tRect.height.toStringAsFixed(1)} '
      'at ${_r(tRect)}. $vp',
    );
  }

  final List<(String, Rect)> others = <(String, Rect)>[];
  for (int i = 1; i <= row.knocks; i += 1) {
    if (_k('knock-card-kn-$i').evaluate().isNotEmpty) {
      others.add((
        'knock-card-kn-$i',
        tester.getRect(_k('knock-card-kn-$i').first),
      ));
    } else {
      bad.add('knock-card-kn-$i: widget not found (fixture). $vp');
    }
  }
  for (int s = 0; s < row.seated; s += 1) {
    if (_k('lobby-seat-$s').evaluate().isNotEmpty) {
      others.add(('lobby-seat-$s', tester.getRect(_k('lobby-seat-$s').first)));
    } else {
      bad.add('lobby-seat-$s: widget not found (fixture). $vp');
    }
  }
  final Finder start = _start();
  if (start.evaluate().isNotEmpty) {
    others.add(('lobby-start-button', tester.getRect(start.first)));
  } else {
    bad.add('lobby-start-button: widget not found (fixture). $vp');
  }
  for (final (String, Rect) o in others) {
    if (swRect.overlaps(o.$2) || tRect.overlaps(o.$2)) {
      bad.add(
        'ApprovalSwitch: expected no intersection with ${o.$1}, switch '
        '${_r(swRect)} target ${_r(tRect)} vs ${o.$1} ${_r(o.$2)}. $vp',
      );
    }
  }

  // Item 2: the tap.
  final Offset centre = tRect.center;
  if (!view.contains(centre)) {
    bad.add('tap: switch centre ${centre.dx},${centre.dy} is outside. $vp');
    return bad;
  }
  final RenderObject? targetBox = target.evaluate().first.renderObject;
  final HitTestResult hit = tester.hitTestOnBinding(centre);
  if (!hit.path.any((HitTestEntry e) => identical(e.target, targetBox))) {
    bad.add(
      'tap: a hit test at the centre ${centre.dx},${centre.dy} of the '
      'approval-switch target does not reach it. $vp',
    );
  }
  final int before = m.sent('set_guest_approval').length;
  await tester.tapAt(centre);
  await tester.pump();
  final List<Map<String, Object?>> after = m
      .sent('set_guest_approval')
      .skip(before)
      .toList();
  final List<Map<String, Object?>> want = <Map<String, Object?>>[
    <String, Object?>{'enabled': !row.approval},
  ];
  if (jsonEncode(after) != jsonEncode(want)) {
    bad.add(
      'tap: expected exactly one set_guest_approval ${jsonEncode(want.first)} '
      '(room guest_approval is ${row.approval}), sent ${jsonEncode(after)}. '
      '$vp',
    );
  }
  return bad;
}

void main() {
  late String install;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    install = await installId();
  });
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      kInstallIdKey: install,
    });
  });

  const List<(double, double)> sizes = <(double, double)>[
    (320, 640),
    (393, 851),
  ];
  const List<String> locales = <String>['en', 'ar'];

  group('host, knocks open: the approval switch stays in reach', () {
    for (final (double, double) size in sizes) {
      for (final String locale in locales) {
        for (final int seated in <int>[2, 4]) {
          for (final int knocks in <int>[1, 2, 3]) {
            // Alternate the room's approval so both directions are tapped.
            final _Row row = _Row(
              knocks: knocks,
              seated: seated,
              width: size.$1,
              height: size.$2,
              locale: locale,
              approval: (knocks + seated) % 2 == 0,
            );
            testWidgets(row.id, (WidgetTester tester) async {
              final _Mounted m = await _mount(tester, row);
              expect(
                tester.takeException(),
                isNull,
                reason: 'overflow or error. ${row.why}',
              );
              final List<String> bad = await _violations(tester, m);
              expect(
                bad,
                isEmpty,
                reason:
                    '${bad.length} violation(s):\n${bad.join('\n')}\n'
                    '${row.why}',
              );
            });
          }
        }
      }
    }
  });

  group('guest and no-knock lobbies', () {
    for (final String locale in locales) {
      final _Row guest = _Row(
        knocks: 2,
        seated: 2,
        width: 393,
        height: 851,
        locale: locale,
        approval: true,
        host: false,
      );
      testWidgets(guest.id, (WidgetTester tester) async {
        await _mount(tester, guest);
        expect(
          find.byType(ApprovalSwitch),
          findsNothing,
          reason:
              'guest lobby with 2 knocks in the snapshot: expected no '
              'ApprovalSwitch. ${guest.why}',
        );
        expect(
          _k('approval-switch'),
          findsNothing,
          reason: 'guest: expected no approval-switch key. ${guest.why}',
        );
      });

      for (final int seated in <int>[2, 4]) {
        final _Row none = _Row(
          knocks: 0,
          seated: seated,
          width: 393,
          height: 851,
          locale: locale,
          approval: false,
        );
        testWidgets(none.id, (WidgetTester tester) async {
          await _mount(tester, none);
          expect(
            find.byType(ApprovalSwitch),
            findsOneWidget,
            reason:
                'host lobby with 0 knocks: expected exactly one '
                'ApprovalSwitch. ${none.why}',
          );
        });
      }
    }
  });
}
