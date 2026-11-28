// Order 727t, widget half: docs/PROTOCOL.md section 38 item 5 and section 37
// item 3 as a player sees them in LobbyScreen (the closing banner and its live
// countdown, the two lobby buttons, the cooldown label, the host notice with
// its single felt cue, the room-closed screen), in English and Arabic.
//
// Written from the spec and the contract of order 727 alone. The widgets name
// no stable key in that contract, so every control is found by its visible
// text. The English literals come from the spec. The Arabic text is read from
// lib/l10n/app_ar.arb by looking up the entry whose English value equals the
// English literal (a data lookup, never a copy of the implementation's
// string), so a missing translation fails with a message saying which.
//
// A real RoomController over FakeTransport with an injected clock, a real
// LobbyScreen, frames pushed one by one. Countdowns are driven by advancing
// the injected clock and the widget test's fake time together, never by a
// real sleep. Replay one case with:
//   flutter test test/c727_lobby_widgets_test.dart --plain-name '<scenario>'
// Every failure names the scenario, the frames pushed and the frames sent.

import 'dart:convert';
import 'dart:io';

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

const String _code = 'K7M2QP';
const String _token = 'tok-c727w-001';

const String _makeEn = 'Make a new room';
const String _joinEn = 'Join another room';
const String _askEn = 'Ask the host to start';
const String _closedEn = 'This room closed because nobody started it';

int _idSeq = 0;
String _frame(String type, Map<String, Object?> data, {String? re}) {
  _idSeq += 1;
  return jsonEncode(<String, Object?>{
    'v': 1,
    't': type,
    'id': 'c727w-srv-${_idSeq.toString().padLeft(6, '0')}',
    're': ?re,
    'd': data,
  });
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;
String _typeOf(String raw) => _decode(raw)['t']! as String;
String _idOf(String raw) => _decode(raw)['id']! as String;

Map<String, Object?> _roomJson({
  required int seq,
  required List<int> seats,
  bool open = false,
  List<int> bots = const <int>[],
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
    for (final int s in seats)
      <String, Object?>{
        'seat': s,
        'name': s == 0 ? 'Sam' : (bots.contains(s) ? '' : 'Bob'),
        'connected': true,
        'tokens': const <int>[-1, -1, -1, -1],
        'client_seed': null,
        'seed_origin': null,
        'via': s == 0 ? 'host' : (bots.contains(s) ? 'bot' : 'link'),
        if (bots.contains(s)) 'bot': 1,
      },
  ],
  'turn': null,
  'winner': null,
  'seq': seq,
  'open': open,
};

class _Recording implements FeedbackService {
  final List<FeedbackCue> played = <FeedbackCue>[];
  @override
  void play(FeedbackCue cue) => played.add(cue);
}

class _Connector {
  final List<FakeTransport> queue = <FakeTransport>[];
  Future<WireTransport> call(Uri url) async {
    if (queue.isEmpty) {
      throw StateError('_Connector: nothing queued');
    }
    return queue.removeAt(0);
  }
}

class _Clock {
  _Clock(this.now);
  DateTime now;
  DateTime call() => now;
}

// --- text helpers ---------------------------------------------------------

String _digits(String s) {
  final StringBuffer b = StringBuffer();
  for (final int c in s.runes) {
    if (c >= 0x660 && c <= 0x669) {
      b.writeCharCode(0x30 + c - 0x660);
    } else if (c >= 0x6F0 && c <= 0x6F9) {
      b.writeCharCode(0x30 + c - 0x6F0);
    } else {
      b.writeCharCode(c);
    }
  }
  return b.toString();
}

Map<String, String>? _arbCache;
String _ar(String en) {
  _arbCache ??= () {
    final Map<String, Object?> e = jsonDecode(
      File('lib/l10n/app_en.arb').readAsStringSync(),
    ) as Map<String, Object?>;
    final Map<String, Object?> a = jsonDecode(
      File('lib/l10n/app_ar.arb').readAsStringSync(),
    ) as Map<String, Object?>;
    final Map<String, String> out = <String, String>{};
    for (final MapEntry<String, Object?> kv in e.entries) {
      final Object? v = kv.value;
      final Object? av = a[kv.key];
      if (!kv.key.startsWith('@') && v is String && av is String) {
        out.putIfAbsent(v, () => av);
      }
    }
    return out;
  }();
  final String? v = _arbCache![en];
  if (v == null) {
    fail(
      'no app_en.arb entry with the value "$en" that also has an Arabic '
      'entry in app_ar.arb: the string is missing or untranslated',
    );
  }
  return v;
}

bool _isArabic(String s) => RegExp(r'[؀-ۿ]').hasMatch(s);

Iterable<String> _allTexts(WidgetTester tester) sync* {
  for (final Element e in find.byType(Text).evaluate()) {
    final Text t = e.widget as Text;
    final String? d = t.data ?? t.textSpan?.toPlainText();
    if (d != null) {
      yield d;
    }
  }
}

final RegExp _clockText = RegExp(r'(?<!\d)(\d{1,2}):(\d{2})(?!\d)');

/// The mm:ss strings currently drawn, digits normalised to ASCII.
List<String> _clockTexts(WidgetTester tester) => <String>[
  for (final String t in _allTexts(tester))
    if (_clockText.hasMatch(_digits(t))) _clockText.firstMatch(_digits(t))![0]!,
];

Finder _text(String s) => find.text(s);

Finder _buttonAncestor(Finder text) => find.ancestor(
  of: text,
  matching: find.byWidgetPredicate(
    (Widget w) => w is ButtonStyleButton || w is InkResponse,
  ),
);

bool _enabled(WidgetTester tester, Finder text) {
  final Finder anc = _buttonAncestor(text);
  if (anc.evaluate().isEmpty) {
    fail('expected a tappable ancestor around $text, found none');
  }
  final Widget w = anc.evaluate().first.widget;
  if (w is ButtonStyleButton) {
    return w.onPressed != null || w.onLongPress != null;
  }
  return (w as InkResponse).onTap != null;
}

/// All buttons (text, enabled), outermost text of each ButtonStyleButton.
List<(String, bool)> _buttons(WidgetTester tester) {
  final List<(String, bool)> out = <(String, bool)>[];
  for (final Element e
      in find
          .byWidgetPredicate((Widget w) => w is ButtonStyleButton)
          .evaluate()) {
    final ButtonStyleButton b = e.widget as ButtonStyleButton;
    final Finder inner = find.descendant(
      of: find.byWidget(b),
      matching: find.byType(Text),
    );
    final String txt = <String>[
      for (final Element t in inner.evaluate())
        ((t.widget as Text).data ??
            (t.widget as Text).textSpan?.toPlainText() ??
            ''),
    ].join(' ');
    out.add((txt, b.onPressed != null));
  }
  return out;
}

void _expectTarget(WidgetTester tester, Finder text, String why) {
  final Finder anc = _buttonAncestor(text);
  expect(anc, findsWidgets, reason: 'no tappable ancestor for $text. $why');
  final Size s = tester.getSize(anc.first);
  expect(
    s.height,
    greaterThanOrEqualTo(48),
    reason: 'tap target height ${s.height} dp is under 48 for $text. $why',
  );
  expect(
    s.width,
    greaterThanOrEqualTo(48),
    reason: 'tap target width ${s.width} dp is under 48 for $text. $why',
  );
}

// --- harness --------------------------------------------------------------

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

class _Lobby {
  _Lobby(
    this.id,
    this.tester,
    this.controller,
    this.transport,
    this.feedback,
    this.clock,
  );

  final String id;
  final WidgetTester tester;
  final RoomController controller;
  final FakeTransport transport;
  final _Recording feedback;
  final _Clock clock;
  final List<String> pushed = <String>[];
  int seq = 1;

  String get why =>
      'scenario "$id"; pushed ${pushed.join(' | ')}; sent '
      '${transport.sentRaw.map(_typeOf).toList()}; cues '
      '${feedback.played.map((FeedbackCue c) => c.id).toList()}; texts '
      '${_allTexts(tester).toList()}. reproduce: flutter test '
      "test/c727_lobby_widgets_test.dart --plain-name '$id'";

  static Future<_Lobby> open(
    WidgetTester tester,
    String id, {
    bool host = false,
    List<int> seats = const <int>[0, 1],
    bool open = false,
    List<int> bots = const <int>[],
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
    connector.queue.add(transport);
    final _Clock clock = _Clock(DateTime.utc(2026, 11, 28, 9));
    final RoomController controller = RoomController(
      serverUrl: Uri.parse('wss://c727w.invalid/ws'),
      connect: connector.call,
      autoReconnectDelays: const <Duration>[],
      clock: clock.call,
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
            open: open,
          ),
        ),
      ),
    );
    await tester.pump();
    final _Lobby l = _Lobby(id, tester, controller, transport, feedback, clock);
    final String reqId = _idOf(transport.sentRaw.last);
    transport.pushText(
      _frame('seat_assigned', <String, Object?>{
        'seat': host ? 0 : 1,
        'seat_token': _token,
      }),
    );
    transport.pushText(
      _frame(
        'room',
        _roomJson(seq: l.seq, seats: seats, open: open, bots: bots),
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

  Future<void> pushRoom({
    required List<int> seats,
    bool open = false,
    List<int> bots = const <int>[],
  }) async {
    seq += 1;
    pushed.add('room(seq $seq, seats $seats)');
    transport.pushText(
      _frame('room', _roomJson(seq: seq, seats: seats, open: open, bots: bots)),
    );
    await tester.pump();
    await tester.pump();
  }

  /// Moves the injected clock and the widget test's fake time together.
  Future<void> advance(Duration d) async {
    clock.now = clock.now.add(d);
    await tester.pump(d);
  }

  Future<void> reply(String type, Map<String, Object?> data) async {
    final String raw = transport.sentRaw.lastWhere(
      (String s) => _typeOf(s) == 'ask_start',
    );
    pushed.add('$type${jsonEncode(data)} (re ask_start)');
    transport.pushText(_frame(type, data, re: _idOf(raw)));
    await tester.pump();
    await tester.pump();
  }

  int get asksSent =>
      transport.sentRaw.where((String s) => _typeOf(s) == 'ask_start').length;
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

  final List<(String, Locale, TextDirection)> locales =
      <(String, Locale, TextDirection)>[
        ('en', const Locale('en'), TextDirection.ltr),
        ('ar', const Locale('ar'), TextDirection.rtl),
      ];

  for (final (String tag, Locale locale, TextDirection dir) in locales) {
    String t(String en) => tag == 'ar' ? _ar(en) : en;

    group('banner and countdown [$tag]', () {
      testWidgets('banner appears only after lobby_closing, with a live '
          'countdown [$tag]', (WidgetTester tester) async {
        final _Lobby l = await _Lobby.open(
          tester,
          'banner after frame $tag',
          host: true,
          locale: locale,
        );
        expect(
          _clockTexts(tester),
          isEmpty,
          reason: 'a countdown is drawn before any lobby_closing. ${l.why}',
        );
        expect(
          _text(t(_makeEn)),
          findsNothing,
          reason: 'the host banner action appeared before the frame. ${l.why}',
        );
        await l.push('lobby_closing', <String, Object?>{'closes_in_s': 120});
        expect(_clockTexts(tester), <String>[
          '2:00',
        ], reason: 'expected exactly one countdown reading 2:00. ${l.why}');
        await l.advance(const Duration(seconds: 1));
        expect(_clockTexts(tester), <String>['1:59'], reason: l.why);
        await l.advance(const Duration(seconds: 59));
        expect(_clockTexts(tester), <String>['1:00'], reason: l.why);
        await l.advance(const Duration(seconds: 54));
        expect(_clockTexts(tester), <String>['0:06'], reason: l.why);
        expect(
          Directionality.of(tester.element(find.byType(LobbyScreen))),
          dir,
          reason: 'wrong text direction for $tag. ${l.why}',
        );
        expect(tester.takeException(), isNull, reason: l.why);
      });

      testWidgets('countdown stops at 0:00 and never goes negative [$tag]', (
        WidgetTester tester,
      ) async {
        final _Lobby l = await _Lobby.open(
          tester,
          'countdown floor $tag',
          locale: locale,
        );
        await l.push('lobby_closing', <String, Object?>{'closes_in_s': 3});
        await l.advance(const Duration(seconds: 10));
        expect(_clockTexts(tester), <String>[
          '0:00',
        ], reason: 'expected 0:00 after the deadline passed. ${l.why}');
        expect(
          _allTexts(tester).any((String s) => _digits(s).contains('-')),
          isFalse,
          reason: 'a negative reading was drawn. ${l.why}',
        );
      });

      testWidgets('a late-attach lobby_closing with 61 s starts at 1:01 '
          '[$tag]', (WidgetTester tester) async {
        final _Lobby l = await _Lobby.open(
          tester,
          'late attach $tag',
          locale: locale,
        );
        await l.push('lobby_closing', <String, Object?>{'closes_in_s': 61});
        expect(_clockTexts(tester), <String>['1:01'], reason: l.why);
      });

      testWidgets('host banner has "Make a new room", guest banner has "Join '
          'another room" [$tag]', (WidgetTester tester) async {
        final _Lobby h = await _Lobby.open(
          tester,
          'host banner action $tag',
          host: true,
          locale: locale,
        );
        await h.push('lobby_closing', <String, Object?>{'closes_in_s': 120});
        expect(_text(t(_makeEn)), findsOneWidget, reason: h.why);
        _expectTarget(tester, _text(t(_makeEn)), h.why);
        expect(_enabled(tester, _text(t(_makeEn))), isTrue, reason: h.why);
      });

      testWidgets('guest banner has "Join another room" and a countdown '
          '[$tag]', (WidgetTester tester) async {
        final _Lobby g = await _Lobby.open(
          tester,
          'guest banner action $tag',
          locale: locale,
        );
        await g.push('lobby_closing', <String, Object?>{'closes_in_s': 120});
        expect(_clockTexts(tester), <String>['2:00'], reason: g.why);
        expect(
          _text(t(_joinEn)),
          findsWidgets,
          reason: 'guest has no Join another room. ${g.why}',
        );
        for (final Element e in _text(t(_joinEn)).evaluate()) {
          expect(e.widget, isA<Text>());
        }
        _expectTarget(tester, _text(t(_joinEn)).first, g.why);
      });

      testWidgets('a guest always has "Join another room", before any '
          'lobby_closing [$tag]', (WidgetTester tester) async {
        final _Lobby g = await _Lobby.open(
          tester,
          'guest join always $tag',
          locale: locale,
        );
        expect(_text(t(_joinEn)), findsWidgets, reason: g.why);
        expect(_clockTexts(tester), isEmpty, reason: g.why);
      });

      testWidgets('arabic strings are Arabic and differ from the English '
          '[$tag]', (WidgetTester tester) async {
        for (final String en in <String>[_makeEn, _joinEn, _askEn, _closedEn]) {
          final String ar = _ar(en);
          expect(
            _isArabic(ar),
            isTrue,
            reason:
                '"$en" has a non-Arabic '
                'translation "$ar"',
          );
          expect(ar, isNot(en), reason: '"$en" is untranslated');
        }
      });
    });

    group('ask the host to start [$tag]', () {
      testWidgets('absent with one seat, present with two [$tag]', (
        WidgetTester tester,
      ) async {
        final _Lobby g = await _Lobby.open(
          tester,
          'ask visibility $tag',
          seats: const <int>[1],
          locale: locale,
        );
        expect(
          _text(t(_askEn)),
          findsNothing,
          reason: 'Ask is shown with one occupied seat. ${g.why}',
        );
        await g.pushRoom(seats: <int>[0, 1]);
        expect(
          _text(t(_askEn)),
          findsOneWidget,
          reason: 'Ask missing with two occupied seats. ${g.why}',
        );
        expect(_enabled(tester, _text(t(_askEn))), isTrue, reason: g.why);
        _expectTarget(tester, _text(t(_askEn)), g.why);
        await g.pushRoom(seats: <int>[1]);
        expect(
          _text(t(_askEn)),
          findsNothing,
          reason: 'Ask stays after the room fell back to one seat. ${g.why}',
        );
      });

      testWidgets('tap sends one ask_start, then is disabled with the '
          'seconds label until the cooldown ends [$tag]', (
        WidgetTester tester,
      ) async {
        final _Lobby g = await _Lobby.open(
          tester,
          'ask cooldown label $tag',
          locale: locale,
        );
        await tester.tap(_text(t(_askEn)));
        await tester.pump();
        expect(g.asksSent, 1, reason: 'one tap must send one ask. ${g.why}');
        await g.reply('ask_start_ok', <String, Object?>{
          'delivered': true,
          'next_in_s': 60,
        });
        expect(
          _text(t(_askEn)),
          findsNothing,
          reason:
              'the plain Ask label should give way to the seconds label '
              'inside the cooldown. ${g.why}',
        );
        List<(String, bool)> labelled() => <(String, bool)>[
          for (final (String, bool) b in _buttons(tester))
            if (RegExp(r'\d').hasMatch(_digits(b.$1))) b,
        ];
        expect(
          labelled(),
          hasLength(1),
          reason: 'expected one button carrying the seconds. ${g.why}',
        );
        expect(
          labelled().first.$2,
          isFalse,
          reason: 'must be disabled. ${g.why}',
        );
        expect(
          _digits(labelled().first.$1),
          contains('60'),
          reason: 'expected 60 seconds. ${g.why}',
        );
        await g.advance(const Duration(seconds: 20));
        expect(
          _digits(labelled().first.$1),
          contains('40'),
          reason: 'expected 40 seconds after 20 s. ${g.why}',
        );
        expect(labelled().first.$2, isFalse, reason: g.why);
        await g.advance(const Duration(seconds: 39));
        expect(
          _digits(labelled().first.$1),
          contains('1'),
          reason: 'expected 1 second at 59 s. ${g.why}',
        );
        expect(labelled().first.$2, isFalse, reason: g.why);
        await g.advance(const Duration(seconds: 1));
        expect(
          _text(t(_askEn)),
          findsOneWidget,
          reason: 'Ask must come back at 60 s. ${g.why}',
        );
        expect(_enabled(tester, _text(t(_askEn))), isTrue, reason: g.why);
        expect(g.asksSent, 1, reason: 'no extra ask was sent. ${g.why}');
      });

      testWidgets('RATE_LIMITED with retry_after_s 41 shows 41 seconds and '
          'a disabled button [$tag]', (WidgetTester tester) async {
        final _Lobby g = await _Lobby.open(
          tester,
          'ask rate limited $tag',
          locale: locale,
        );
        await tester.tap(_text(t(_askEn)));
        await tester.pump();
        await g.reply('error', <String, Object?>{
          'code': 'RATE_LIMITED',
          'message': 'slow',
          'retry_after_s': 41,
        });
        final List<(String, bool)> labelled = <(String, bool)>[
          for (final (String, bool) b in _buttons(tester))
            if (RegExp(r'\d').hasMatch(_digits(b.$1))) b,
        ];
        expect(labelled, hasLength(1), reason: g.why);
        expect(_digits(labelled.first.$1), contains('41'), reason: g.why);
        expect(labelled.first.$2, isFalse, reason: g.why);
        expect(
          g.controller.phase,
          RoomPhase.connected,
          reason: 'a refused ask dropped the connection. ${g.why}',
        );
      });

      testWidgets('the disabled cooldown button sends nothing when tapped '
          '[$tag]', (WidgetTester tester) async {
        final _Lobby g = await _Lobby.open(
          tester,
          'ask disabled tap $tag',
          locale: locale,
        );
        await tester.tap(_text(t(_askEn)));
        await tester.pump();
        await g.reply('ask_start_ok', <String, Object?>{
          'delivered': true,
          'next_in_s': 60,
        });
        final int sent = g.transport.sentRaw.length;
        final Finder btn = find.byWidgetPredicate(
          (Widget w) => w is ButtonStyleButton && w.onPressed == null,
        );
        if (btn.evaluate().isNotEmpty) {
          await tester.tap(btn.last, warnIfMissed: false);
          await tester.pump();
        }
        expect(
          g.transport.sentRaw.length,
          sent,
          reason: 'a tap inside the cooldown sent a frame. ${g.why}',
        );
      });
    });

    group('host notice [$tag]', () {
      testWidgets('start_asked names the asker and plays your_turn once per '
          'serial and no other cue [$tag]', (WidgetTester tester) async {
        final _Lobby h = await _Lobby.open(
          tester,
          'host notice $tag',
          host: true,
          locale: locale,
        );
        expect(
          _allTexts(tester).any((String s) => s.contains('Zaidx')),
          isFalse,
          reason: 'fixture: the asker name must not be on screen yet. ${h.why}',
        );
        await h.push('lobby_closing', <String, Object?>{'closes_in_s': 120});
        expect(
          h.feedback.played,
          isEmpty,
          reason: 'lobby_closing must not play a cue. ${h.why}',
        );
        await h.push('start_asked', <String, Object?>{
          'seat': 1,
          'name': 'Zaidx',
        });
        expect(
          _allTexts(tester).where((String s) => s.contains('Zaidx')),
          isNotEmpty,
          reason: 'the notice does not name the asker. ${h.why}',
        );
        expect(
          h.feedback.played.map((FeedbackCue c) => c.id).toList(),
          <String>['your_turn'],
          reason: 'expected exactly one your_turn id. ${h.why}',
        );
        await h.push('start_asked', <String, Object?>{
          'seat': 1,
          'name': 'Zaidx',
        });
        expect(
          h.feedback.played.map((FeedbackCue c) => c.id).toList(),
          <String>['your_turn', 'your_turn'],
          reason: 'the same asker twice must be felt twice. ${h.why}',
        );
        await h.pushRoom(seats: <int>[0, 1, 2]);
        await h.advance(const Duration(seconds: 1));
        expect(
          h.feedback.played.length,
          2,
          reason: 'a rebuild or a room push replayed the cue. ${h.why}',
        );
        expect(tester.takeException(), isNull, reason: h.why);
      });

      testWidgets('the notice is transient and does not take the banner '
          'down [$tag]', (WidgetTester tester) async {
        final _Lobby h = await _Lobby.open(
          tester,
          'host notice transient $tag',
          host: true,
          locale: locale,
        );
        await h.push('lobby_closing', <String, Object?>{'closes_in_s': 120});
        await h.push('start_asked', <String, Object?>{
          'seat': 1,
          'name': 'Zaidx',
        });
        await h.advance(const Duration(seconds: 60));
        expect(
          _allTexts(tester).any((String s) => s.contains('Zaidx')),
          isFalse,
          reason: 'the notice never went away. ${h.why}',
        );
        expect(_clockTexts(tester), <String>[
          '1:00',
        ], reason: 'the banner must persist. ${h.why}');
      });
    });

    group('closed screen [$tag]', () {
      for (final bool host in <bool>[true, false]) {
        final String who = host ? 'host' : 'guest';
        testWidgets('room_closed lobby_timeout shows the calm screen for the '
            '$who [$tag]', (WidgetTester tester) async {
          final _Lobby l = await _Lobby.open(
            tester,
            'closed screen $who $tag',
            host: host,
            locale: locale,
          );
          await l.push('lobby_closing', <String, Object?>{'closes_in_s': 2});
          await l.push('room_closed', <String, Object?>{
            'reason': 'lobby_timeout',
          });
          await tester.pump(const Duration(seconds: 1));
          expect(
            _text(t(_closedEn)),
            findsOneWidget,
            reason: 'the calm line is missing. ${l.why}',
          );
          expect(
            _text(t(_makeEn)),
            findsOneWidget,
            reason: 'primary action missing. ${l.why}',
          );
          expect(
            _text(t(_joinEn)),
            findsOneWidget,
            reason: 'secondary action missing. ${l.why}',
          );
          _expectTarget(tester, _text(t(_makeEn)), l.why);
          _expectTarget(tester, _text(t(_joinEn)), l.why);
          expect(_enabled(tester, _text(t(_makeEn))), isTrue, reason: l.why);
          expect(_enabled(tester, _text(t(_joinEn))), isTrue, reason: l.why);
          // Primary above secondary (reading order, both directions).
          expect(
            tester.getTopLeft(_text(t(_makeEn))).dy,
            lessThan(tester.getTopLeft(_text(t(_joinEn))).dy),
            reason: 'primary must sit above secondary. ${l.why}',
          );
          expect(
            _allTexts(tester)
                .where((String s) => s.toLowerCase().contains('error')),
            isEmpty,
            reason: 'the word error is on the closed screen. ${l.why}',
          );
          expect(
            _allTexts(tester).where((String s) => s.contains('lobby_timeout')),
            isEmpty,
            reason: 'a raw reason code is on screen. ${l.why}',
          );
          expect(
            _clockTexts(tester),
            isEmpty,
            reason: 'a countdown is still drawn after the close. ${l.why}',
          );
          expect(
            Directionality.of(tester.element(find.byType(Scaffold).first)),
            dir,
            reason: l.why,
          );
          expect(tester.takeException(), isNull, reason: l.why);
        });
      }

      testWidgets('closing without lobby_closing first still shows the calm '
          'screen [$tag]', (WidgetTester tester) async {
        final _Lobby l = await _Lobby.open(
          tester,
          'closed screen direct $tag',
          locale: locale,
        );
        await l.push('room_closed', <String, Object?>{
          'reason': 'lobby_timeout',
        });
        await tester.pump(const Duration(seconds: 1));
        expect(_text(t(_closedEn)), findsOneWidget, reason: l.why);
        expect(
          _allTexts(tester)
              .where((String s) => s.toLowerCase().contains('error')),
          isEmpty,
          reason: l.why,
        );
      });
    });
  }

  group('no Ask for the host', () {
    testWidgets('a host with a guest seated sees no Ask button', (
      WidgetTester tester,
    ) async {
      final _Lobby h = await _Lobby.open(
        tester,
        'host no ask two seats',
        host: true,
      );
      await h.push('lobby_closing', <String, Object?>{'closes_in_s': 120});
      expect(_text(_askEn), findsNothing, reason: h.why);
    });

    testWidgets('a vs-computer lobby shows the host no Ask button', (
      WidgetTester tester,
    ) async {
      final _Lobby h = await _Lobby.open(
        tester,
        'host no ask vs computer',
        host: true,
        seats: const <int>[0, 1],
        bots: const <int>[1],
      );
      expect(_text(_askEn), findsNothing, reason: h.why);
      expect(
        _clockTexts(tester),
        isEmpty,
        reason: 'no banner without the frame in a computer room. ${h.why}',
      );
    });

    testWidgets('an open-room lobby shows the host no Ask button', (
      WidgetTester tester,
    ) async {
      final _Lobby h = await _Lobby.open(
        tester,
        'host no ask open room',
        host: true,
        open: true,
        seats: const <int>[0, 1],
      );
      expect(_text(_askEn), findsNothing, reason: h.why);
      await h.push('lobby_closing', <String, Object?>{'closes_in_s': 120});
      expect(_text(_askEn), findsNothing, reason: h.why);
    });

    testWidgets('a lone host in an open room sees no Ask button', (
      WidgetTester tester,
    ) async {
      final _Lobby h = await _Lobby.open(
        tester,
        'host no ask alone open',
        host: true,
        open: true,
        seats: const <int>[0],
      );
      expect(_text(_askEn), findsNothing, reason: h.why);
    });
  });

  group('large text and narrow width', () {
    testWidgets('banner, countdown and both guest buttons fit at 1.6x text '
        'on a 320 dp screen, in English', (WidgetTester tester) async {
      final _Lobby g = await _Lobby.open(
        tester,
        'large text guest en',
        width: 320,
        textScale: 1.6,
      );
      await g.push('lobby_closing', <String, Object?>{'closes_in_s': 120});
      expect(_clockTexts(tester), <String>['2:00'], reason: g.why);
      expect(tester.takeException(), isNull, reason: 'overflow. ${g.why}');
      for (final String s in <String>[_askEn, _joinEn]) {
        expect(_text(s), findsWidgets, reason: '$s missing. ${g.why}');
        _expectTarget(tester, _text(s).first, g.why);
        final Rect r = tester.getRect(_text(s).first);
        expect(
          r.left >= 0 && r.right <= 320,
          isTrue,
          reason: '$s is clipped off a 320 dp screen: $r. ${g.why}',
        );
      }
      final Rect c = tester.getRect(
        find.byWidgetPredicate(
          (Widget w) => w is Text && _clockText.hasMatch(_digits(w.data ?? '')),
        ),
      );
      expect(
        c.left >= 0 && c.right <= 320,
        isTrue,
        reason: 'countdown clipped: $c. ${g.why}',
      );
    });

    testWidgets('banner and closed screen fit at 1.6x text in Arabic', (
      WidgetTester tester,
    ) async {
      final _Lobby h = await _Lobby.open(
        tester,
        'large text host ar',
        host: true,
        width: 320,
        textScale: 1.6,
        locale: const Locale('ar'),
      );
      await h.push('lobby_closing', <String, Object?>{'closes_in_s': 120});
      expect(_clockTexts(tester), <String>['2:00'], reason: h.why);
      expect(tester.takeException(), isNull, reason: 'overflow. ${h.why}');
      _expectTarget(tester, _text(_ar(_makeEn)), h.why);
      await h.push('room_closed', <String, Object?>{'reason': 'lobby_timeout'});
      await tester.pump(const Duration(seconds: 1));
      expect(_text(_ar(_closedEn)), findsOneWidget, reason: h.why);
      _expectTarget(tester, _text(_ar(_makeEn)), h.why);
      _expectTarget(tester, _text(_ar(_joinEn)), h.why);
      expect(tester.takeException(), isNull, reason: 'overflow. ${h.why}');
    });
  });
}
