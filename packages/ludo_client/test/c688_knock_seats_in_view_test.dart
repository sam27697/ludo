// C-688t: with knocks open on the host's lobby, the seats stay in view
// (order 688, finding X213, doctrine P3).
//
// Written from the order alone. On the host's lobby with 1, 2 or 3 knocks
// open and 2 or 4 seats occupied, at 320x640 and 393x851 logical px, text
// scale 1.0, en and ar:
//   1. every occupied seat card is fully inside the viewport without
//      scrolling and does not intersect the Start control or a knock card;
//   2. every open knock's accept and reject targets are fully visible,
//      hittable at their centre and at least 48x48 dp;
//   3. the Start control is fully visible and hittable.
// At text scale 2.0 and 320x640 nothing overflows and every item 1 to 3
// widget is reachable by scrolling. With 0 knocks the layout is the one on
// main today (item 4): the seats and Start are present and reachable by
// scrolling, nothing overflows. Item 4 does not promise the seats are in
// view without scrolling at 320x640 with no knock, and on 597c93f they are
// not, so that is not asserted.
//
// A real RoomController over FakeTransport, a real LobbyScreen. One test per
// row; the row id is the --plain-name needle.
//
// Replay: flutter test test/c688_knock_seats_in_view_test.dart \
//   --plain-name '<row id>'
// Every failure names the row, the widget, both rects and the viewport.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:flutter_test/flutter_test.dart' as ft show testWidgets;
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://c688-knock-seats.invalid/ws';
const String _code = 'K7M2QP';
const String _linkId = 't5k2q9a-x7m3pd';
const String _token = 'tok-c688-001';

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'c688-srv-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

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

Map<String, Object?> _roomJson({required int seated, required int knocks}) =>
    <String, Object?>{
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
      'guest_approval': true,
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
    required this.scale,
  });

  final int knocks;
  final int seated;
  final double width;
  final double height;
  final String locale;
  final double scale;

  String get id =>
      'k$knocks.seated$seated.${width.toInt()}x${height.toInt()}.$locale'
      '.scale${scale.toStringAsFixed(1)}';

  String get why =>
      'row "$id". reproduce: flutter test '
      "test/c688_knock_seats_in_view_test.dart --plain-name '$id'";
}

Future<void> _mount(WidgetTester tester, _Row row) async {
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
      builder: (BuildContext context, Widget? child) {
        final MediaQueryData data = MediaQuery.of(context);
        return MediaQuery(
          data: data.copyWith(textScaler: TextScaler.linear(row.scale)),
          child: child!,
        );
      },
      home: FeedbackScope(
        settings: FeedbackSettings.forTest(),
        service: _Silent(),
        child: LobbyScreen(
          controller: controller,
          action: LobbyAction.create,
          playerName: 'Sam',
          players: 4,
        ),
      ),
    ),
  );
  await tester.pump();
  final String reqId = _decode(transport.sentRaw.last)['id']! as String;
  transport.pushText(
    _frame('seat_assigned', <String, Object?>{'seat': 0, 'seat_token': _token}),
  );
  transport.pushText(
    _frame(
      'room',
      _roomJson(seated: row.seated, knocks: row.knocks),
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

/// The Start control of the host's lobby: either of the two keyed variants.
Finder _start() {
  final Finder plain = _k('lobby-start-button');
  final Finder present = _k('lobby-start-with-present-button');
  return plain.evaluate().isNotEmpty ? plain : present;
}

/// True when a hit test at the centre of [f] reaches that widget's render box.
bool _hittable(WidgetTester tester, Finder f) {
  final RenderObject? target = f.evaluate().first.renderObject;
  final HitTestResult result = tester.hitTestOnBinding(tester.getCenter(f));
  return result.path.any((HitTestEntry e) => identical(e.target, target));
}

/// Items 1 to 3 as a list of violations; [scrolled] makes every widget be
/// scrolled into view first (text scale 2.0 rows).
Future<List<String>> _violations(
  WidgetTester tester,
  _Row row, {
  required bool scrolled,
}) async {
  final List<String> bad = <String>[];
  final Rect view = Offset.zero & Size(row.width, row.height);
  final String vp = 'viewport ${_r(view)}';

  Future<Rect?> place(String what, Finder f) async {
    if (f.evaluate().isEmpty) {
      bad.add('$what: widget not found. $vp');
      return null;
    }
    if (scrolled) {
      try {
        await tester.ensureVisible(f.first);
        await tester.pump();
      } catch (e) {
        bad.add('$what: could not be scrolled into view ($e). $vp');
      }
    }
    return tester.getRect(f.first);
  }

  final Finder start = _start();
  final List<(String, Rect)> blockers = <(String, Rect)>[];
  final Rect? startRect = await place('start control', start);
  if (startRect != null) {
    blockers.add(('start control', startRect));
    if (!_inside(startRect, view)) {
      bad.add(
        'start control: expected fully inside the viewport, saw '
        '${_r(startRect)}. $vp',
      );
    } else if (!_hittable(tester, start.first)) {
      bad.add(
        'start control: centre tap does not reach it, rect ${_r(startRect)}. '
        '$vp',
      );
    }
  }

  final List<(String, Rect)> knockRects = <(String, Rect)>[];
  for (int i = 1; i <= row.knocks; i += 1) {
    final Rect? card = await place('knock-card-kn-$i', _k('knock-card-kn-$i'));
    if (card != null) {
      knockRects.add(('knock-card-kn-$i', card));
    }
    for (final String kind in <String>['accept', 'reject']) {
      final String name = 'knock-$kind-kn-$i';
      final Finder f = _k(name);
      final Rect? rect = await place(name, f);
      if (rect == null) {
        continue;
      }
      if (!_inside(rect, view)) {
        bad.add(
          '$name: expected fully inside the viewport, saw ${_r(rect)}. $vp',
        );
      } else if (!_hittable(tester, f.first)) {
        bad.add('$name: centre tap does not reach it, rect ${_r(rect)}. $vp');
      }
      if (rect.width < 48 - 0.01 || rect.height < 48 - 0.01) {
        bad.add(
          '$name: expected at least 48x48 dp, saw '
          '${rect.width.toStringAsFixed(1)}x${rect.height.toStringAsFixed(1)} '
          'at ${_r(rect)}. $vp',
        );
      }
    }
  }
  blockers.addAll(knockRects);

  for (int s = 0; s < row.seated; s += 1) {
    final String name = 'lobby-seat-$s';
    final Rect? rect = await place(name, _k(name));
    if (rect == null) {
      continue;
    }
    if (!_inside(rect, view)) {
      bad.add(
        '$name: expected fully inside the viewport, saw ${_r(rect)}. $vp',
      );
    }
    for (final (String, Rect) b in blockers) {
      if (rect.overlaps(b.$2)) {
        bad.add(
          '$name: expected no intersection with ${b.$1}, '
          'seat ${_r(rect)} vs ${b.$1} ${_r(b.$2)}. $vp',
        );
      }
    }
  }
  return bad;
}

void main() {
  const List<(double, double)> sizes = <(double, double)>[
    (320, 640),
    (393, 851),
  ];
  const List<String> locales = <String>['en', 'ar'];

  group('knocks open, seats in view at text scale 1.0', () {
    for (final (double, double) size in sizes) {
      for (final String locale in locales) {
        for (final int seated in <int>[2, 4]) {
          for (final int knocks in <int>[1, 2, 3]) {
            final _Row row = _Row(
              knocks: knocks,
              seated: seated,
              width: size.$1,
              height: size.$2,
              locale: locale,
              scale: 1.0,
            );
            testWidgets(row.id, (WidgetTester tester) async {
              await _mount(tester, row);
              final Object? thrown = tester.takeException();
              expect(thrown, isNull, reason: 'overflow or error. ${row.why}');
              final List<String> bad = await _violations(
                tester,
                row,
                scrolled: false,
              );
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

  group(
    'no knocks: lobby unchanged, seats and Start present and reachable',
    () {
      for (final (double, double) size in sizes) {
        for (final String locale in locales) {
          for (final int seated in <int>[2, 4]) {
            final _Row row = _Row(
              knocks: 0,
              seated: seated,
              width: size.$1,
              height: size.$2,
              locale: locale,
              scale: 1.0,
            );
            testWidgets(row.id, (WidgetTester tester) async {
              await _mount(tester, row);
              expect(
                _k('knock-bar').evaluate().isEmpty ||
                    find
                        .byWidgetPredicate((Widget w) {
                          final Key? k = w.key;
                          return k is ValueKey<String> &&
                              k.value.startsWith('knock-card-');
                        })
                        .evaluate()
                        .isEmpty,
                isTrue,
                reason: 'fixture: expected no knock card. ${row.why}',
              );
              final List<String> bad = await _violations(
                tester,
                row,
                scrolled: true,
              );
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
    },
  );

  group(
    'text scale 2.0 at 320x640: no overflow, all reachable by scrolling',
    () {
      for (final String locale in locales) {
        for (final int seated in <int>[2, 4]) {
          for (final int knocks in <int>[1, 2, 3]) {
            final _Row row = _Row(
              knocks: knocks,
              seated: seated,
              width: 320,
              height: 640,
              locale: locale,
              scale: 2.0,
            );
            testWidgets(row.id, (WidgetTester tester) async {
              await _mount(tester, row);
              expect(
                tester.takeException(),
                isNull,
                reason: 'expected no overflow after mount. ${row.why}',
              );
              final List<String> bad = await _violations(
                tester,
                row,
                scrolled: true,
              );
              expect(
                tester.takeException(),
                isNull,
                reason: 'expected no overflow after scrolling. ${row.why}',
              );
              // Only reachability matters here: each widget, once scrolled to,
              // must be inside the viewport and hittable. Intersections with
              // other widgets are measured at scale 1.0 only.
              final List<String> reach = <String>[
                for (final String b in bad)
                  if (!b.contains('expected no intersection')) b,
              ];
              expect(
                reach,
                isEmpty,
                reason:
                    '${reach.length} violation(s):\n${reach.join('\n')}\n'
                    '${row.why}',
              );
            });
          }
        }
      }
    },
  );
}
