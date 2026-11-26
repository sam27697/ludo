// C-682t: the host's side of the lobby (order 682, docs/PROTOCOL.md section 31
// items 1 to 6): seat origin marks, the approval switch, the knock bar and the
// lobby kick.
//
// Written from work/ludo/orders/682-lobby-ui-approval-knock-kick.md and the
// frozen 681 interface alone. A real RoomController over FakeTransport, frames
// pushed one by one, a real LobbyScreen. Nothing of the lib's new widgets is
// imported: the tests find them by the stable keys the order names.
//
// New keys this file depends on (order 682, none exists before its lib lands):
//   seat-origin-<seat>, approval-switch, knock-card-<id>, knock-accept-<id>,
//   knock-reject-<id>, lobby-kick-<seat>.
// New strings it depends on: "Approve typed codes", "Anyone typing the code
// waits for your tap", and the semantics words "joined by link" and "joined
// with the code" (en; the Arabic is only checked to differ and to be Arabic).
//
// Countdown: the knock ring is measured with the test clock (pump with a
// Duration), never pumpAndSettle.
//
// Replay: flutter test test/c682_lobby_test.dart --plain-name '<scenario>'
// Every failure names the scenario, the frames pushed and the frames sent.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:flutter_test/flutter_test.dart' as ft show testWidgets;
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/install_id.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://c682-lobby.invalid/ws';
const String _code = 'K7M2QP';
const String _linkId = 't5k2q9a-x7m3pd';
const String _token = 'tok-c682-001';

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'c682-srv-${_serverIdSeq.toString().padLeft(6, '0')}';
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

Map<String, Object?> _knockJson(String id, String name, [int ms = 60000]) =>
    <String, Object?>{'knock_id': id, 'name': name, 'expires_ms': ms};

Map<String, Object?> _roomJson({
  required int seq,
  required List<(int, String)> seats,
  bool approval = false,
  List<Map<String, Object?>> knocks = const <Map<String, Object?>>[],
  int players = 4,
}) => <String, Object?>{
  'code': _code,
  'state': 'LOBBY',
  'host_seat': 0,
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
  'seats': <Map<String, Object?>>[
    for (final (int, String) s in seats)
      <String, Object?>{
        'seat': s.$1,
        'name': s.$2.split('|').first,
        'connected': true,
        'tokens': const <int>[-1, -1, -1, -1],
        'client_seed': null,
        'seed_origin': null,
        'via': s.$1 == 0 ? 'host' : s.$2.split('|').last,
      },
  ],
  'turn': null,
  'winner': null,
  'seq': seq,
  'link_id': _linkId,
  'guest_approval': approval,
  'knocks': knocks,
};

class _Recording implements FeedbackService {
  final List<FeedbackCue> played = <FeedbackCue>[];
  @override
  void play(FeedbackCue cue) => played.add(cue);
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

/// Every controller made by [_Lobby.open] is disposed inside the test body so
/// no 10 s request timer is pending at the framework's invariant check.
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

class _Lobby {
  _Lobby(this.id, this.tester, this.controller, this.transport, this.feedback);

  final String id;
  final WidgetTester tester;
  final RoomController controller;
  final FakeTransport transport;
  final _Recording feedback;
  final List<String> pushed = <String>[];
  int _seq = 10;

  String get why =>
      'scenario "$id"; pushed ${pushed.join(' | ')}; sent '
      '${transport.sentRaw.map(_typeOf).toList()}; cues '
      '${feedback.played.map((FeedbackCue c) => c.id).toList()}. reproduce: '
      "flutter test test/c682_lobby_test.dart --plain-name '$id'";

  /// Mounts the lobby as the host (seat 0) or as guest seat 1.
  /// [others] are the other seated players as (seat, 'Name|via').
  static Future<_Lobby> open(
    WidgetTester tester,
    String id, {
    bool host = true,
    List<(int, String)> others = const <(int, String)>[(1, 'Bob|link')],
    bool approval = false,
    List<Map<String, Object?>> knocks = const <Map<String, Object?>>[],
    Locale locale = const Locale('en'),
    double width = 400,
    double textScale = 1.0,
  }) async {
    tester.view.physicalSize = Size(width * 2, 900 * 2);
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
    final _Recording feedback = _Recording();
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
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
        home: FeedbackScope(
          settings: FeedbackSettings.forTest(),
          service: feedback,
          child: LobbyScreen(
            controller: controller,
            action: host ? LobbyAction.create : LobbyAction.join,
            code: host ? null : _code,
            playerName: host ? 'Sam' : 'Bob',
            players: 4,
          ),
        ),
      ),
    );
    await tester.pump();
    final _Lobby l = _Lobby(id, tester, controller, transport, feedback);
    final String reqId = _decode(transport.sentRaw.last)['id']! as String;
    final int mine = host ? 0 : 1;
    transport.pushText(
      _frame('seat_assigned', <String, Object?>{
        'seat': mine,
        'seat_token': _token,
      }),
    );
    final List<(int, String)> seats = <(int, String)>[
      (0, 'Sam|host'),
      if (!host && !others.any(((int, String) s) => s.$1 == 1)) (1, 'Bob|link'),
      ...others,
    ]..sort(((int, String) a, (int, String) b) => a.$1.compareTo(b.$1));
    transport.pushText(
      _frame(
        'room',
        _roomJson(
          seq: l._seq,
          seats: <(int, String)>[
            for (final (int, String) s in seats) (s.$1, s.$2),
          ],
          approval: approval,
          knocks: host ? knocks : const <Map<String, Object?>>[],
        ),
        re: reqId,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(
      controller.phase,
      RoomPhase.connected,
      reason: 'fixture: expected connected. ${l.why}',
    );
    feedback.played.clear();
    return l;
  }

  Future<void> push(String type, Map<String, Object?> data) async {
    pushed.add('$type${jsonEncode(data)}');
    transport.pushText(_frame(type, data));
    await tester.pump();
    await tester.pump();
  }

  Future<void> pushKnock(String id, String name, [int ms = 60000]) async {
    _seq += 1;
    await push('knock', <String, Object?>{
      ..._knockJson(id, name, ms),
      'seq': _seq,
    });
  }

  Future<void> pushClosed(String id, String outcome) async {
    _seq += 1;
    await push('knock_closed', <String, Object?>{
      'knock_id': id,
      'outcome': outcome,
      'seq': _seq,
    });
  }

  List<Map<String, Object?>> sent(String type) => <Map<String, Object?>>[
    for (final String raw in transport.sentRaw)
      if (_typeOf(raw) == type) _dataOf(raw),
  ];
}

// --- finders and measures --------------------------------------------------

Finder _k(String key) => find.byKey(Key(key));

bool _isArabic(String s) => RegExp(r'[؀-ۿ]').hasMatch(s);

Iterable<String> _texts(WidgetTester tester, Finder within) sync* {
  for (final Element e
      in find.descendant(of: within, matching: find.byType(Text)).evaluate()) {
    final Text t = e.widget as Text;
    final String? d = t.data ?? t.textSpan?.toPlainText();
    if (d != null) {
      yield d;
    }
  }
}

/// A shape signature of everything drawn inside [key]: icons and painters.
String _signature(WidgetTester tester, String key) {
  final Finder f = _k(key);
  final List<String> parts = <String>[];
  for (final Element e
      in find.descendant(of: f, matching: find.byType(Icon)).evaluate()) {
    parts.add('icon:${(e.widget as Icon).icon?.codePoint}');
  }
  for (final Element e
      in find
          .descendant(of: f, matching: find.byType(CustomPaint))
          .evaluate()) {
    parts.add('paint:${(e.widget as CustomPaint).painter.runtimeType}');
  }
  for (final Element e
      in find.descendant(of: f, matching: find.byType(Text)).evaluate()) {
    parts.add('text:${(e.widget as Text).data}');
  }
  return parts.join(',');
}

String _label(WidgetTester tester, String key) {
  final SemanticsHandle h = tester.ensureSemantics();
  final String label = tester.getSemantics(_k(key)).label;
  h.dispose();
  return label;
}

/// How full the knock's ring or bar is, 0 to 1, read from a progress
/// indicator or a fractional box inside the card; null when there is none.
double? _fill(WidgetTester tester, String id) {
  final Finder card = _k('knock-card-$id');
  for (final Element e
      in find
          .descendant(of: card, matching: find.byType(ProgressIndicator))
          .evaluate()) {
    final double? v = (e.widget as ProgressIndicator).value;
    if (v != null) {
      return v;
    }
  }
  for (final Element e
      in find
          .descendant(of: card, matching: find.byType(FractionallySizedBox))
          .evaluate()) {
    final FractionallySizedBox b = e.widget as FractionallySizedBox;
    final double? v = b.widthFactor ?? b.heightFactor;
    if (v != null) {
      return v;
    }
  }
  return null;
}

bool _switchOn(WidgetTester tester) {
  final Widget w = tester.widget(_k('approval-switch'));
  if (w is Switch) {
    return w.value;
  }
  if (w is SwitchListTile) {
    return w.value;
  }
  return tester
      .widget<Switch>(
        find
            .descendant(
              of: _k('approval-switch'),
              matching: find.byType(Switch),
            )
            .first,
      )
      .value;
}

const String _hint = 'Anyone typing the code waits for your tap';
const String _switchLabel = 'Approve typed codes';

void main() {
  // Section 32 item 6: a typed-code join waits for the install id. A launched
  // app has read or made it already, so the fixtures do the same once, and
  // every test starts from a store that holds only that id (a record one test
  // saves must not turn the next test's join into a resume).
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

  // ===========================================================================
  // 1. Seat origin marks (P3)
  // ===========================================================================
  group('seat origin', () {
    testWidgets('link, code and approved each draw a mark; the three differ', (
      tester,
    ) async {
      final _Lobby l = await _Lobby.open(
        tester,
        'origin.marks',
        others: const <(int, String)>[
          (1, 'Ann|link'),
          (2, 'Bea|code'),
          (3, 'Cat|approved'),
        ],
      );
      for (final int s in <int>[1, 2, 3]) {
        expect(
          _k('seat-origin-$s'),
          findsOneWidget,
          reason: 'expected a seat-origin-$s mark on its card. ${l.why}',
        );
      }
      final String link = _signature(tester, 'seat-origin-1');
      final String code = _signature(tester, 'seat-origin-2');
      final String approved = _signature(tester, 'seat-origin-3');
      expect(
        <String>{link, code, approved}.length,
        3,
        reason:
            'expected three different glyphs (link, keypad, keypad with a '
            'check); saw link="$link" code="$code" approved="$approved". '
            '${l.why}',
      );
    });

    testWidgets('unknown draws no mark', (tester) async {
      final _Lobby l = await _Lobby.open(
        tester,
        'origin.unknown',
        others: const <(int, String)>[(1, 'Ann|unknown')],
      );
      expect(
        _k('seat-origin-1'),
        findsNothing,
        reason: 'expected no mark for via unknown. ${l.why}',
      );
    });

    testWidgets('a via string the client does not know reads as unknown', (
      tester,
    ) async {
      final _Lobby l = await _Lobby.open(
        tester,
        'origin.future_value',
        others: const <(int, String)>[(1, 'Ann|teleport')],
      );
      expect(
        _k('seat-origin-1'),
        findsNothing,
        reason: 'expected no mark and no crash for a future via. ${l.why}',
      );
      expect(tester.takeException(), isNull, reason: l.why);
    });

    testWidgets('semantics label says it in English', (tester) async {
      final _Lobby l = await _Lobby.open(
        tester,
        'origin.label_en',
        others: const <(int, String)>[
          (1, 'Ann|link'),
          (2, 'Bea|code'),
          (3, 'Cat|approved'),
        ],
      );
      final String linkLabel = _label(tester, 'lobby-seat-1').toLowerCase();
      final String codeLabel = _label(tester, 'lobby-seat-2').toLowerCase();
      final String approvedLabel = _label(tester, 'lobby-seat-3').toLowerCase();
      expect(
        linkLabel,
        contains('joined by link'),
        reason: 'expected "joined by link" in the card label. ${l.why}',
      );
      expect(
        codeLabel,
        contains('joined with the code'),
        reason: 'expected "joined with the code" in the card label. ${l.why}',
      );
      expect(
        approvedLabel,
        isNot(contains('joined by link')),
        reason: 'an approved seat did not come by link. ${l.why}',
      );
      expect(
        approvedLabel,
        isNotEmpty,
        reason: 'expected a label for the approved seat. ${l.why}',
      );
    });

    testWidgets('semantics label for a host seat names no way of joining', (
      tester,
    ) async {
      final _Lobby l = await _Lobby.open(tester, 'origin.host_label');
      final String hostLabel = _label(tester, 'lobby-seat-0').toLowerCase();
      expect(hostLabel, isNot(contains('joined by link')), reason: l.why);
      expect(hostLabel, isNot(contains('joined with the code')), reason: l.why);
    });

    testWidgets('Arabic label is Arabic and the card does not overflow', (
      tester,
    ) async {
      final _Lobby l = await _Lobby.open(
        tester,
        'origin.label_ar',
        locale: const Locale('ar'),
        others: const <(int, String)>[(1, 'Ann|link'), (2, 'Bea|code')],
      );
      final String linkLabel = _label(tester, 'lobby-seat-1');
      final String codeLabel = _label(tester, 'lobby-seat-2');
      expect(
        linkLabel,
        isNot(contains('joined')),
        reason: 'expected the Arabic phrase, not English. ${l.why}',
      );
      expect(
        _isArabic(linkLabel),
        isTrue,
        reason: 'label "$linkLabel". ${l.why}',
      );
      expect(
        _isArabic(codeLabel),
        isTrue,
        reason: 'label "$codeLabel". ${l.why}',
      );
      expect(
        linkLabel,
        isNot(codeLabel),
        reason: 'link and code seats need different labels. ${l.why}',
      );
      expect(tester.takeException(), isNull, reason: l.why);
    });

    testWidgets('the mark mirrors in Arabic', (tester) async {
      Future<double> offsetFromStart(Locale locale, String id) async {
        final _Lobby l = await _Lobby.open(
          tester,
          id,
          locale: locale,
          others: const <(int, String)>[(1, 'Ann|link')],
        );
        final Rect card = tester.getRect(_k('lobby-seat-1'));
        final Rect mark = tester.getRect(_k('seat-origin-1'));
        final bool rtl = locale.languageCode == 'ar';
        expect(card.contains(mark.center), isTrue, reason: l.why);
        return rtl ? card.right - mark.right : mark.left - card.left;
      }

      final double en = await offsetFromStart(
        const Locale('en'),
        'origin.mirror_en',
      );
      for (final RoomController c in _owned) {
        c.dispose();
      }
      _owned.clear();
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 11));
      final double ar = await offsetFromStart(
        const Locale('ar'),
        'origin.mirror_ar',
      );
      expect(
        (en - ar).abs() <= 1.0,
        isTrue,
        reason:
            'expected the mark the same distance from the START edge in en '
            'and ar (rtl mirror); en $en, ar $ar. scenario origin.mirror_*',
      );
    });
  });

  // ===========================================================================
  // 2. Approval switch (P5)
  // ===========================================================================
  group('approval switch', () {
    testWidgets('host sees it with its label; a guest does not', (
      tester,
    ) async {
      final _Lobby l = await _Lobby.open(tester, 'switch.host_sees');
      expect(_k('approval-switch'), findsOneWidget, reason: 'host: ${l.why}');
      expect(
        find.text(_switchLabel),
        findsOneWidget,
        reason: 'expected the label "$_switchLabel" once. ${l.why}',
      );
    });

    testWidgets('a guest never sees the switch, even with approval on', (
      tester,
    ) async {
      final _Lobby l = await _Lobby.open(
        tester,
        'switch.guest_blind',
        host: false,
        approval: true,
      );
      expect(_k('approval-switch'), findsNothing, reason: 'guest: ${l.why}');
      expect(find.text(_switchLabel), findsNothing, reason: l.why);
      expect(find.text(_hint), findsNothing, reason: l.why);
    });

    testWidgets('tapping it once sends set_guest_approval enabled true', (
      tester,
    ) async {
      final _Lobby l = await _Lobby.open(tester, 'switch.tap_on');
      expect(_switchOn(tester), isFalse, reason: 'fixture. ${l.why}');
      await tester.tap(_k('approval-switch'));
      await tester.pump();
      expect(
        l.sent('set_guest_approval'),
        <Map<String, Object?>>[
          <String, Object?>{'enabled': true},
        ],
        reason:
            'expected exactly one set_guest_approval {enabled:true}. ${l.why}',
      );
    });

    testWidgets('with approval on, one tap sends enabled false', (
      tester,
    ) async {
      final _Lobby l = await _Lobby.open(
        tester,
        'switch.tap_off',
        approval: true,
      );
      expect(_switchOn(tester), isTrue, reason: 'fixture. ${l.why}');
      await tester.tap(_k('approval-switch'));
      await tester.pump();
      expect(
        l.sent('set_guest_approval'),
        <Map<String, Object?>>[
          <String, Object?>{'enabled': false},
        ],
        reason:
            'expected exactly one set_guest_approval {enabled:false}. ${l.why}',
      );
    });

    testWidgets('the hint shows only while approval is on', (tester) async {
      final _Lobby l = await _Lobby.open(tester, 'switch.hint');
      expect(find.text(_hint), findsNothing, reason: 'off: ${l.why}');
      l._seq += 1;
      await l.push(
        'room',
        _roomJson(
          seq: l._seq,
          seats: const <(int, String)>[(0, 'Sam|host')],
          approval: true,
        ),
      );
      expect(find.text(_hint), findsOneWidget, reason: 'on: ${l.why}');
      expect(
        _switchOn(tester),
        isTrue,
        reason: 'switch follows the snapshot. ${l.why}',
      );
      l._seq += 1;
      await l.push(
        'room',
        _roomJson(seq: l._seq, seats: const <(int, String)>[(0, 'Sam|host')]),
      );
      expect(find.text(_hint), findsNothing, reason: 'off again: ${l.why}');
      expect(_switchOn(tester), isFalse, reason: l.why);
    });

    testWidgets('the Arabic label and hint are Arabic', (tester) async {
      final _Lobby l = await _Lobby.open(
        tester,
        'switch.ar',
        locale: const Locale('ar'),
        approval: true,
      );
      expect(_k('approval-switch'), findsOneWidget, reason: 'host: ${l.why}');
      expect(find.text(_switchLabel), findsNothing, reason: l.why);
      expect(find.text(_hint), findsNothing, reason: l.why);
      final Iterable<String> inside = _texts(tester, _k('approval-switch'));
      final bool arabicLabel =
          inside.any(_isArabic) ||
          find
              .byWidgetPredicate((Widget w) {
                return w is Text && _isArabic(w.data ?? '');
              })
              .evaluate()
              .isNotEmpty;
      expect(arabicLabel, isTrue, reason: 'expected Arabic text. ${l.why}');
    });
  });

  // ===========================================================================
  // 3. Knock bar (host only)
  // ===========================================================================
  group('knock bar', () {
    testWidgets('no knocks, no cards', (tester) async {
      final _Lobby l = await _Lobby.open(tester, 'knock.none');
      expect(
        find.byWidgetPredicate((Widget w) {
          final Key? k = w.key;
          return k is ValueKey<String> && k.value.startsWith('knock-card-');
        }),
        findsNothing,
        reason: l.why,
      );
    });

    testWidgets('one card per knock, name shown, above the seat cards', (
      tester,
    ) async {
      final _Lobby l = await _Lobby.open(tester, 'knock.cards');
      await l.pushKnock('kn-1', 'Ann');
      await l.pushKnock('kn-2', 'Zed');
      expect(_k('knock-card-kn-1'), findsOneWidget, reason: l.why);
      expect(_k('knock-card-kn-2'), findsOneWidget, reason: l.why);
      expect(
        find.descendant(of: _k('knock-card-kn-1'), matching: find.text('Ann')),
        findsOneWidget,
        reason: 'expected the knocker name on its card. ${l.why}',
      );
      expect(
        find.descendant(of: _k('knock-card-kn-2'), matching: find.text('Zed')),
        findsOneWidget,
        reason: l.why,
      );
      final double seatTop = tester.getTopLeft(_k('lobby-seat-0')).dy;
      for (final String id in <String>['kn-1', 'kn-2']) {
        expect(
          tester.getBottomLeft(_k('knock-card-$id')).dy <= seatTop,
          isTrue,
          reason:
              'expected card $id above the seat cards (seat top $seatTop). ${l.why}',
        );
      }
      expect(
        tester.getTopLeft(_k('knock-card-kn-1')).dy <
            tester.getTopLeft(_k('knock-card-kn-2')).dy,
        isTrue,
        reason: 'expected arrival order top to bottom. ${l.why}',
      );
    });

    testWidgets('a snapshot that already holds knocks shows them', (
      tester,
    ) async {
      final _Lobby l = await _Lobby.open(
        tester,
        'knock.in_snapshot',
        knocks: <Map<String, Object?>>[_knockJson('kn-9', 'Mo', 40000)],
      );
      expect(_k('knock-card-kn-9'), findsOneWidget, reason: l.why);
    });

    testWidgets('a closed knock leaves, the other stays', (tester) async {
      final _Lobby l = await _Lobby.open(tester, 'knock.closed');
      await l.pushKnock('kn-1', 'Ann');
      await l.pushKnock('kn-2', 'Zed');
      await l.pushClosed('kn-1', 'withdrawn');
      await tester.pump(const Duration(seconds: 1));
      expect(_k('knock-card-kn-1'), findsNothing, reason: l.why);
      expect(_k('knock-card-kn-2'), findsOneWidget, reason: l.why);
    });

    testWidgets('a guest never sees a knock card', (tester) async {
      final _Lobby l = await _Lobby.open(tester, 'knock.guest', host: false);
      await l.pushKnock('kn-1', 'Ann');
      expect(_k('knock-card-kn-1'), findsNothing, reason: 'guest: ${l.why}');
    });

    testWidgets('Accept sends answer_knock accept true for that id only', (
      tester,
    ) async {
      final _Lobby l = await _Lobby.open(tester, 'knock.accept');
      await l.pushKnock('kn-1', 'Ann');
      await l.pushKnock('kn-2', 'Zed');
      await tester.tap(_k('knock-accept-kn-2'));
      await tester.pump();
      expect(l.sent('answer_knock'), <Map<String, Object?>>[
        <String, Object?>{'knock_id': 'kn-2', 'accept': true},
      ], reason: 'expected one answer_knock {kn-2, true}. ${l.why}');
    });

    testWidgets('Reject sends answer_knock accept false for that id only', (
      tester,
    ) async {
      final _Lobby l = await _Lobby.open(tester, 'knock.reject');
      await l.pushKnock('kn-1', 'Ann');
      await l.pushKnock('kn-2', 'Zed');
      await tester.tap(_k('knock-reject-kn-1'));
      await tester.pump();
      expect(l.sent('answer_knock'), <Map<String, Object?>>[
        <String, Object?>{'knock_id': 'kn-1', 'accept': false},
      ], reason: 'expected one answer_knock {kn-1, false}. ${l.why}');
    });

    testWidgets('both targets are at least 48 dp and carry a shape', (
      tester,
    ) async {
      final _Lobby l = await _Lobby.open(tester, 'knock.targets');
      await l.pushKnock('kn-1', 'Ann');
      for (final String key in <String>[
        'knock-accept-kn-1',
        'knock-reject-kn-1',
      ]) {
        final Size size = tester.getSize(_k(key));
        expect(
          size.width >= 48 && size.height >= 48,
          isTrue,
          reason: 'expected $key >= 48x48 dp, saw $size. ${l.why}',
        );
        expect(
          find.descendant(of: _k(key), matching: find.byType(Icon)),
          findsWidgets,
          reason:
              'expected a check or cross Icon inside $key (never colour alone). ${l.why}',
        );
      }
      expect(
        _signature(tester, 'knock-accept-kn-1'),
        isNot(_signature(tester, 'knock-reject-kn-1')),
        reason:
            'accept and reject must differ in shape, not only colour. ${l.why}',
      );
    });

    testWidgets('the ring drains with the test clock', (tester) async {
      final _Lobby l = await _Lobby.open(tester, 'knock.drain');
      await l.pushKnock('kn-1', 'Ann', 60000);
      final double? start = _fill(tester, 'kn-1');
      expect(
        start,
        isNotNull,
        reason:
            'expected a ProgressIndicator or FractionallySizedBox inside '
            'knock-card-kn-1 carrying the remaining fraction. ${l.why}',
      );
      expect(
        start! > 0.9,
        isTrue,
        reason: 'expected full at 60 s, saw $start. ${l.why}',
      );
      await tester.pump(const Duration(seconds: 30));
      final double half = _fill(tester, 'kn-1')!;
      expect(
        half > 0.35 && half < 0.65,
        isTrue,
        reason: 'expected about half after 30 of 60 s, saw $half. ${l.why}',
      );
      await tester.pump(const Duration(seconds: 29));
      final double nearly = _fill(tester, 'kn-1')!;
      expect(
        nearly < 0.1,
        isTrue,
        reason: 'expected nearly empty after 59 of 60 s, saw $nearly. ${l.why}',
      );
    });

    testWidgets('a knock that arrives with 20 s left starts at a third', (
      tester,
    ) async {
      final _Lobby l = await _Lobby.open(tester, 'knock.partial');
      await l.pushKnock('kn-1', 'Ann', 20000);
      final double? start = _fill(tester, 'kn-1');
      expect(start, isNotNull, reason: l.why);
      expect(
        start! > 0.2 && start < 0.45,
        isTrue,
        reason: 'expected 20 s of 60 s, about 0.33, saw $start. ${l.why}',
      );
    });

    testWidgets('an arriving knock plays your_turn and nothing else', (
      tester,
    ) async {
      final _Lobby l = await _Lobby.open(tester, 'knock.cue');
      await l.pushKnock('kn-1', 'Ann');
      expect(l.feedback.played, <FeedbackCue>[
        FeedbackCue.yourTurn,
      ], reason: 'expected exactly one your_turn on arrival. ${l.why}');
      await l.pushKnock('kn-2', 'Zed');
      expect(l.feedback.played, <FeedbackCue>[
        FeedbackCue.yourTurn,
        FeedbackCue.yourTurn,
      ], reason: 'expected one your_turn per knock. ${l.why}');
      await l.pushClosed('kn-1', 'rejected');
      await tester.pump(const Duration(seconds: 1));
      expect(
        l.feedback.played.length,
        2,
        reason: 'a closing knock plays no cue. ${l.why}',
      );
    });

    testWidgets('a replayed knock frame (old seq) plays no second cue', (
      tester,
    ) async {
      final _Lobby l = await _Lobby.open(tester, 'knock.cue_replay');
      await l.pushKnock('kn-1', 'Ann');
      l.transport.pushText(
        _frame('knock', <String, Object?>{
          ..._knockJson('kn-1', 'Ann'),
          'seq': 11,
        }),
      );
      await tester.pump();
      await tester.pump();
      expect(l.feedback.played, <FeedbackCue>[
        FeedbackCue.yourTurn,
      ], reason: 'expected no second cue for a replayed seq. ${l.why}');
      expect(
        find.byWidgetPredicate((Widget w) {
          final Key? k = w.key;
          return k is ValueKey<String> && k.value == 'knock-card-kn-1';
        }),
        findsOneWidget,
        reason: 'expected one card for one knock. ${l.why}',
      );
    });

    testWidgets('a guest hears nothing when a knock frame arrives', (
      tester,
    ) async {
      final _Lobby l = await _Lobby.open(
        tester,
        'knock.cue_guest',
        host: false,
      );
      await l.pushKnock('kn-1', 'Ann');
      expect(l.feedback.played, isEmpty, reason: l.why);
    });

    testWidgets('no overflow at 320 dp and text scale 2.0 with three knocks', (
      tester,
    ) async {
      for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
        final _Lobby l = await _Lobby.open(
          tester,
          'knock.overflow.${locale.languageCode}',
          locale: locale,
          width: 320,
          textScale: 2.0,
          approval: true,
          others: const <(int, String)>[
            (1, 'Abdulrahman Alhaddad|code'),
            (2, 'Bea|approved'),
            (3, 'Cat|link'),
          ],
        );
        await l.pushKnock('kn-1', 'Abdulrahman Alhaddad');
        await l.pushKnock('kn-2', 'Fatima Al Mansoori');
        await l.pushKnock('kn-3', 'Zed');
        expect(
          tester.takeException(),
          isNull,
          reason: 'expected no overflow or exception. ${l.why}',
        );
        for (final String id in <String>['kn-1', 'kn-2', 'kn-3']) {
          for (final String kind in <String>['accept', 'reject']) {
            final Size size = tester.getSize(_k('knock-$kind-$id'));
            expect(
              size.width >= 48 && size.height >= 48,
              isTrue,
              reason:
                  'expected $kind $id >= 48 dp at scale 2, saw $size. ${l.why}',
            );
          }
        }
        for (final RoomController c in _owned) {
          c.dispose();
        }
        _owned.clear();
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 11));
      }
    });
  });

  // ===========================================================================
  // 4. Lobby kick (P1)
  // ===========================================================================
  group('lobby kick', () {
    testWidgets('present on other seats, absent on the host own seat', (
      tester,
    ) async {
      final _Lobby l = await _Lobby.open(
        tester,
        'kick.presence',
        others: const <(int, String)>[(1, 'Ann|link'), (2, 'Bea|code')],
      );
      expect(_k('lobby-kick-1'), findsOneWidget, reason: l.why);
      expect(_k('lobby-kick-2'), findsOneWidget, reason: l.why);
      expect(
        _k('lobby-kick-0'),
        findsNothing,
        reason: 'the host has no kick on their own seat. ${l.why}',
      );
    });

    testWidgets('a guest has no kick control anywhere', (tester) async {
      final _Lobby l = await _Lobby.open(
        tester,
        'kick.guest',
        host: false,
        others: const <(int, String)>[(2, 'Bea|code')],
      );
      for (final int s in <int>[0, 1, 2, 3]) {
        expect(_k('lobby-kick-$s'), findsNothing, reason: 'seat $s. ${l.why}');
      }
    });

    testWidgets('an empty seat has no kick', (tester) async {
      final _Lobby l = await _Lobby.open(tester, 'kick.empty');
      expect(_k('lobby-kick-2'), findsNothing, reason: l.why);
      expect(_k('lobby-kick-3'), findsNothing, reason: l.why);
    });

    testWidgets('the control is a 48 dp target', (tester) async {
      final _Lobby l = await _Lobby.open(tester, 'kick.target');
      final Size size = tester.getSize(_k('lobby-kick-1'));
      expect(
        size.width >= 48 && size.height >= 48,
        isTrue,
        reason: 'expected lobby-kick-1 >= 48x48 dp, saw $size. ${l.why}',
      );
    });

    testWidgets('opening the sheet sends nothing; confirm sends kick', (
      tester,
    ) async {
      final _Lobby l = await _Lobby.open(
        tester,
        'kick.confirm',
        others: const <(int, String)>[(1, 'Ann|link'), (2, 'Bea|code')],
      );
      await tester.tap(_k('lobby-kick-2'));
      await tester.pump(Duration.zero);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));

      expect(
        find.text('Remove'),
        findsOneWidget,
        reason: 'expected the kick sheet. ${l.why}',
      );
      expect(
        l.sent('kick'),
        isEmpty,
        reason: 'opening must send nothing. ${l.why}',
      );
      await tester.tap(find.text('Remove'));
      await tester.pump(Duration.zero);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      expect(l.sent('kick'), <Map<String, Object?>>[
        <String, Object?>{'seat': 2},
      ], reason: 'expected exactly one kick {seat:2}. ${l.why}');
    });

    testWidgets('cancelling sends nothing and closes the sheet', (
      tester,
    ) async {
      final _Lobby l = await _Lobby.open(tester, 'kick.cancel');
      await tester.tap(_k('lobby-kick-1'));
      await tester.pump(Duration.zero);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Keep'), findsOneWidget, reason: l.why);
      await tester.tap(find.text('Keep'));
      await tester.pump(Duration.zero);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      expect(l.sent('kick'), isEmpty, reason: 'cancel sends nothing. ${l.why}');
      expect(find.text('Keep'), findsNothing, reason: 'sheet closed. ${l.why}');
    });

    testWidgets('after the server frees the seat the card empties', (
      tester,
    ) async {
      final _Lobby l = await _Lobby.open(tester, 'kick.card_leaves');
      await tester.tap(_k('lobby-kick-1'));
      await tester.pump(Duration.zero);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(find.text('Remove'));
      await tester.pump(Duration.zero);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      l._seq += 1;
      await l.push(
        'room',
        _roomJson(seq: l._seq, seats: const <(int, String)>[(0, 'Sam|host')]),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(
        _k('lobby-seat-1'),
        findsNothing,
        reason: 'card should be gone. ${l.why}',
      );
      expect(_k('lobby-kick-1'), findsNothing, reason: l.why);
      expect(_k('seat-origin-1'), findsNothing, reason: l.why);
    });
  });
}
