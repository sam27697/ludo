// C-682t: the typed-code joiner's side (order 682 item 5, docs/PROTOCOL.md
// section 31 items 3, 4, 6, 7, 8).
//
// Written from work/ludo/orders/682-lobby-ui-approval-knock-kick.md and the
// frozen 681 interface alone. A real HomeScreen over a real RoomController on
// FakeTransport; the join is a typed code on the home screen, the server's
// answers are pushed as frames.
//
// New keys this file depends on: knock-waiting, knock-waiting-cancel.
// New strings it depends on: "Waiting for the host", "The host removed you
// from this room", "You cannot knock on this room again", "Too many people are
// waiting, try again in a minute". The outcome lines (rejected, timed out,
// full, switched off) are not worded by the order, so they are measured as the
// text the screen gains after the frame: rejected and timed out must be the
// same, the others must differ from them, Arabic must be Arabic.
//
// Countdown: pumped on the test clock, never pumpAndSettle.
//
// Replay: flutter test test/c682_joiner_test.dart --plain-name '<scenario>'

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart'
    show LobbyScreen, lobbyErrorMessage;
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

const String _code = 'K7M2QP';
const String _linkId = 't5k2q9a-x7m3pd';

int _serverIdSeq = 0;
String _frame(String type, Map<String, Object?> data, {String? re}) {
  _serverIdSeq += 1;
  return jsonEncode(<String, Object?>{
    'v': 1,
    't': type,
    'id': 'c682j-srv-${_serverIdSeq.toString().padLeft(6, '0')}',
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
  'link_id': _linkId,
  'guest_approval': false,
  'knocks': const <Object?>[],
};

class _Join {
  _Join(this.id, this.tester);

  final String id;
  final WidgetTester tester;
  final List<FakeTransport> transports = <FakeTransport>[];
  final List<String> pushed = <String>[];
  int _next = 0;

  FakeTransport get transport => transports.last;

  String get why =>
      'scenario "$id"; pushed ${pushed.join(' | ')}; sent '
      '${transports.map((FakeTransport t) => t.sentRaw.map(_typeOf).toList()).toList()}. '
      "reproduce: flutter test test/c682_joiner_test.dart --plain-name '$id'";

  static Future<_Join> open(
    WidgetTester tester,
    String id, {
    Locale locale = const Locale('en'),
    int transportsQueued = 2,
    double width = 400,
    double textScale = 1.0,
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.physicalSize = Size(width * 2, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final _Join j = _Join(id, tester);
    final List<FakeTransport> queue = <FakeTransport>[
      for (int i = 0; i < transportsQueued; i += 1) FakeTransport(),
    ];
    RoomController factory() => RoomController(
      serverUrl: Uri.parse('wss://c682-joiner.invalid/ws'),
      connect: (Uri url) async {
        final FakeTransport t = queue[j._next];
        j._next += 1;
        j.transports.add(t);
        return t as WireTransport;
      },
      autoReconnectDelays: const <Duration>[],
    );
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
        home: HomeScreen(onToggleLocale: () {}, controllerFactory: factory),
      ),
    );
    await tester.pump();
    await tester.pump();
    return j;
  }

  Set<String> visibleTexts() {
    final Set<String> out = <String>{};
    for (final Element e in find.byType(Text).evaluate()) {
      final Text t = e.widget as Text;
      final String? d = t.data ?? t.textSpan?.toPlainText();
      if (d != null && d.trim().isNotEmpty) {
        out.add(d);
      }
    }
    return out;
  }

  bool get _sentJoin =>
      transports.isNotEmpty &&
      transport.sentRaw.any((String r) => _typeOf(r) == 'join_room');

  Future<void> tapJoin() async {
    await tester.ensureVisible(find.byKey(const Key('join-room-button')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('join-room-button')));
    await tester.pump();
    await tester.pump();
  }

  /// Types the code and taps Join; returns once the join_room frame is sent.
  Future<void> typeAndJoin() async {
    await tester.enterText(find.byKey(const Key('room-code-field')), _code);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tapJoin();
    for (int i = 0; i < 20 && !_sentJoin; i += 1) {
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      transport.sentRaw.map(_typeOf),
      contains('join_room'),
      reason: 'fixture: expected join_room to be sent. $why',
    );
  }

  String get joinId {
    final String raw = transport.sentRaw.firstWhere(
      (String r) => _typeOf(r) == 'join_room',
    );
    return _decode(raw)['id']! as String;
  }

  Future<void> push(
    String type,
    Map<String, Object?> data, {
    bool reply = false,
  }) async {
    pushed.add('$type${jsonEncode(data)}');
    transport.pushText(_frame(type, data, re: reply ? joinId : null));
    await tester.pump();
    await tester.pump();
  }

  Future<void> knockPending({int ms = 60000, String knockId = 'kn-me'}) => push(
    'knock_pending',
    <String, Object?>{'knock_id': knockId, 'expires_ms': ms},
    reply: true,
  );

  Future<void> knockFailed(String outcome, {String knockId = 'kn-me'}) => push(
    'knock_failed',
    <String, Object?>{'knock_id': knockId, 'outcome': outcome},
  );

  /// Pumps until [cond] holds or [limit] of the test clock passes.
  Future<bool> waitFor(
    bool Function() cond, {
    Duration limit = const Duration(seconds: 12),
  }) async {
    Duration spent = Duration.zero;
    while (!cond() && spent < limit) {
      await tester.pump(const Duration(milliseconds: 250));
      spent += const Duration(milliseconds: 250);
    }
    return cond();
  }

  bool get onHome =>
      find.byKey(const Key('room-code-field')).evaluate().isNotEmpty &&
      find.byKey(const Key('knock-waiting')).evaluate().isEmpty &&
      find.byType(LobbyScreen, skipOffstage: false).evaluate().isEmpty;

  String get codeText {
    final Finder f = find.byKey(const Key('room-code-field'));
    if (f.evaluate().length != 1) {
      return '<room-code-field found ${f.evaluate().length} times; $why>';
    }
    return tester.widget<TextField>(f).controller!.text;
  }

  Future<void> finish() async {
    await tester.pump(const Duration(seconds: 12));
  }
}

bool _isArabic(String s) => RegExp(r'[؀-ۿ]').hasMatch(s);

/// The sorted text the screen gained between [before] and [after].
List<String> _gained(Set<String> before, Set<String> after) =>
    after.difference(before).toList()..sort();

void main() {
  group('pending: the waiting card', () {
    testWidgets('knock_pending shows the full-screen waiting card', (
      tester,
    ) async {
      final _Join j = await _Join.open(tester, 'pending.card');
      await j.typeAndJoin();
      expect(
        find.byKey(const Key('knock-waiting')),
        findsNothing,
        reason: 'no waiting card before the server answers. ${j.why}',
      );
      await j.knockPending();
      expect(
        find.byKey(const Key('knock-waiting')),
        findsOneWidget,
        reason: 'expected the waiting card after knock_pending. ${j.why}',
      );
      expect(
        find.text('Waiting for the host'),
        findsOneWidget,
        reason: 'expected the line "Waiting for the host". ${j.why}',
      );
      expect(
        find.byKey(const Key('knock-waiting-cancel')),
        findsOneWidget,
        reason: 'expected a Cancel. ${j.why}',
      );
      final Size size = tester.getSize(
        find.byKey(const Key('knock-waiting-cancel')),
      );
      expect(
        size.width >= 48 && size.height >= 48,
        isTrue,
        reason: 'expected Cancel >= 48 dp, saw $size. ${j.why}',
      );
      await j.finish();
    });

    testWidgets('the ring drains with the test clock', (tester) async {
      final _Join j = await _Join.open(tester, 'pending.drain');
      await j.typeAndJoin();
      await j.knockPending(ms: 60000);
      double? fill() {
        final Finder card = find.byKey(const Key('knock-waiting'));
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
                .descendant(
                  of: card,
                  matching: find.byType(FractionallySizedBox),
                )
                .evaluate()) {
          final FractionallySizedBox b = e.widget as FractionallySizedBox;
          final double? v = b.widthFactor ?? b.heightFactor;
          if (v != null) {
            return v;
          }
        }
        return null;
      }

      final double? start = fill();
      expect(
        start,
        isNotNull,
        reason:
            'expected a ProgressIndicator or FractionallySizedBox inside '
            'knock-waiting carrying the remaining fraction. ${j.why}',
      );
      await tester.pump(const Duration(seconds: 30));
      final double half = fill()!;
      expect(
        half < start! && half > 0.35 && half < 0.65,
        isTrue,
        reason:
            'expected about half after 30 s, start $start, saw $half. ${j.why}',
      );
      await j.finish();
    });

    testWidgets('Cancel sends leave_room and returns home with the code kept', (
      tester,
    ) async {
      final _Join j = await _Join.open(tester, 'pending.cancel');
      await j.typeAndJoin();
      await j.knockPending();
      await tester.tap(find.byKey(const Key('knock-waiting-cancel')));
      await tester.pump();
      await tester.pump();
      expect(
        j.transport.sentRaw.map(_typeOf),
        contains('leave_room'),
        reason: 'expected Cancel to leave (leave_room on the wire). ${j.why}',
      );
      expect(
        await j.waitFor(() => j.onHome),
        isTrue,
        reason: 'expected the home screen back within 12 s. ${j.why}',
      );
      expect(
        j.codeText,
        _code,
        reason: 'expected the code field kept after Cancel. ${j.why}',
      );
      expect(
        find.byKey(const Key('knock-waiting')),
        findsNothing,
        reason: j.why,
      );
      await j.finish();
    });
  });

  group('outcomes', () {
    Future<List<String>> outcomeLines(
      WidgetTester tester,
      String outcome,
      Locale locale,
      String id,
    ) async {
      final _Join j = await _Join.open(tester, id, locale: locale);
      final Set<String> before = j.visibleTexts();
      await j.typeAndJoin();
      await j.knockPending();
      await j.knockFailed(outcome);
      expect(
        await j.waitFor(() => j.onHome),
        isTrue,
        reason: 'expected home after $outcome. ${j.why}',
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        j.codeText,
        _code,
        reason: 'expected the code field kept after $outcome. ${j.why}',
      );
      final List<String> gained = _gained(before, j.visibleTexts());
      await j.finish();
      return gained;
    }

    for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
      final String lang = locale.languageCode;

      testWidgets('[$lang] each outcome puts one plain line on home', (
        tester,
      ) async {
        for (final String outcome in <String>[
          'rejected',
          'timeout',
          'full',
          'switched_off',
        ]) {
          final List<String> lines = await outcomeLines(
            tester,
            outcome,
            locale,
            'outcome.$lang.$outcome',
          );
          expect(
            lines,
            isNotEmpty,
            reason:
                'expected a new line on home after $outcome ($lang), saw '
                'none. scenario outcome.$lang.$outcome',
          );
          if (lang == 'ar') {
            expect(
              lines.any(_isArabic),
              isTrue,
              reason: 'expected an Arabic line after $outcome, saw $lines',
            );
          }
          await tester.pumpWidget(const SizedBox());
        }
      });

      testWidgets('[$lang] rejected and timed out read exactly the same', (
        tester,
      ) async {
        final List<String> rejected = await outcomeLines(
          tester,
          'rejected',
          locale,
          'outcome.$lang.same.rejected',
        );
        await tester.pumpWidget(const SizedBox());
        final List<String> timedOut = await outcomeLines(
          tester,
          'timeout',
          locale,
          'outcome.$lang.same.timeout',
        );
        expect(
          timedOut,
          rejected,
          reason:
              'expected identical text for rejected and timed out ($lang), '
              'so a stranger learns nothing. rejected $rejected, timed out '
              '$timedOut',
        );
        expect(rejected, isNotEmpty, reason: 'expected a line ($lang)');
        final String joined = rejected.join(' ').toLowerCase();
        for (final String blame in <String>[
          'reject',
          'refus',
          'denied',
          'declin',
        ]) {
          expect(
            joined,
            isNot(contains(blame)),
            reason: 'no blame wording ($blame) in the $lang line: $rejected',
          );
        }
      });

      testWidgets('[$lang] full and switched off differ from rejected', (
        tester,
      ) async {
        final List<String> rejected = await outcomeLines(
          tester,
          'rejected',
          locale,
          'outcome.$lang.diff.rejected',
        );
        await tester.pumpWidget(const SizedBox());
        final List<String> full = await outcomeLines(
          tester,
          'full',
          locale,
          'outcome.$lang.diff.full',
        );
        await tester.pumpWidget(const SizedBox());
        final List<String> off = await outcomeLines(
          tester,
          'switched_off',
          locale,
          'outcome.$lang.diff.off',
        );
        expect(
          full,
          isNot(rejected),
          reason: 'a full room is not a rejection ($lang): $full vs $rejected',
        );
        expect(
          off,
          isNot(rejected),
          reason: 'a switch-off is not a rejection ($lang): $off vs $rejected',
        );
      });
    }

    testWidgets('accepted goes into the lobby as a normal join', (
      tester,
    ) async {
      final _Join j = await _Join.open(tester, 'outcome.accepted');
      await j.typeAndJoin();
      await j.knockPending();
      await j.push('seat_assigned', <String, Object?>{
        'seat': 1,
        'seat_token': 'tok-c682-j1',
      });
      await j.push('room', _room(5));
      await tester.pump(const Duration(seconds: 1));
      expect(
        find.byKey(const Key('knock-waiting')),
        findsNothing,
        reason: 'expected the waiting card gone once seated. ${j.why}',
      );
      expect(
        find.byKey(const Key('lobby-seat-1')),
        findsOneWidget,
        reason: 'expected the lobby with my seat. ${j.why}',
      );
      await j.finish();
    });
  });

  group('kicked', () {
    testWidgets('wasKicked shows its line once, then home', (tester) async {
      final _Join j = await _Join.open(tester, 'kicked.once');
      await j.typeAndJoin();
      await j.push('seat_assigned', <String, Object?>{
        'seat': 1,
        'seat_token': 'tok-c682-j2',
      });
      await j.push('room', _room(5), reply: true);
      await tester.pump(const Duration(seconds: 1));
      await j.push('kicked', <String, Object?>{});
      expect(
        await j.waitFor(() => j.onHome),
        isTrue,
        reason: 'expected home after kicked. ${j.why}',
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        find.text('The host removed you from this room'),
        findsOneWidget,
        reason: 'expected the kicked line exactly once. ${j.why}',
      );
      // A second attempt reaches the lobby or the waiting card; the old line
      // must not come back with it.
      await j.tapJoin();
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump();
      expect(
        find.text('The host removed you from this room'),
        findsNothing,
        reason: 'expected the kicked line shown once only. ${j.why}',
      );
      await j.finish();
    });

    testWidgets('the Arabic kicked line is Arabic', (tester) async {
      final _Join j = await _Join.open(
        tester,
        'kicked.ar',
        locale: const Locale('ar'),
      );
      final Set<String> before = j.visibleTexts();
      await j.typeAndJoin();
      await j.push('seat_assigned', <String, Object?>{
        'seat': 1,
        'seat_token': 'tok-c682-j3',
      });
      await j.push('room', _room(5), reply: true);
      await tester.pump(const Duration(seconds: 1));
      await j.push('kicked', <String, Object?>{});
      expect(await j.waitFor(() => j.onHome), isTrue, reason: j.why);
      await tester.pump(const Duration(milliseconds: 600));
      final List<String> gained = _gained(before, j.visibleTexts());
      expect(
        gained.any(_isArabic),
        isTrue,
        reason:
            'expected a new Arabic line after kicked, saw $gained. ${j.why}',
      );
      await j.finish();
    });
  });

  group('error codes', () {
    test('lobbyErrorMessage maps the three new codes in English', () async {
      final AppLocalizations loc = await AppLocalizations.delegate.load(
        const Locale('en'),
      );
      expect(
        lobbyErrorMessage(loc, 'KNOCK_REFUSED'),
        'You cannot knock on this room again',
        reason: 'KNOCK_REFUSED line',
      );
      expect(
        lobbyErrorMessage(loc, 'KICKED'),
        'The host removed you from this room',
        reason: 'KICKED must read as wasKicked does',
      );
      expect(
        lobbyErrorMessage(loc, 'TOO_MANY_KNOCKS'),
        'Too many people are waiting, try again in a minute',
        reason: 'TOO_MANY_KNOCKS line',
      );
    });

    test(
      'in Arabic they are Arabic, distinct and not the generic line',
      () async {
        final AppLocalizations loc = await AppLocalizations.delegate.load(
          const Locale('ar'),
        );
        final String generic = lobbyErrorMessage(loc, 'SOMETHING_ELSE');
        final Map<String, String> lines = <String, String>{
          for (final String c in <String>[
            'KNOCK_REFUSED',
            'KICKED',
            'TOO_MANY_KNOCKS',
          ])
            c: lobbyErrorMessage(loc, c),
        };
        for (final MapEntry<String, String> e in lines.entries) {
          expect(_isArabic(e.value), isTrue, reason: '${e.key}: ${e.value}');
          expect(
            e.value,
            isNot(generic),
            reason: '${e.key} must have its own line, not the generic one',
          );
        }
        expect(
          lines.values.toSet().length,
          3,
          reason: 'three different lines expected, saw $lines',
        );
      },
    );

    for (final (String, String) c in const <(String, String)>[
      ('KNOCK_REFUSED', 'You cannot knock on this room again'),
      ('KICKED', 'The host removed you from this room'),
      ('TOO_MANY_KNOCKS', 'Too many people are waiting, try again in a minute'),
    ]) {
      testWidgets('a join refused ${c.$1} says so on screen', (tester) async {
        final _Join j = await _Join.open(tester, 'error.${c.$1}');
        await j.typeAndJoin();
        await j.push('error', <String, Object?>{
          'code': c.$1,
          'message': '',
        }, reply: true);
        await tester.pump(const Duration(seconds: 1));
        expect(
          find.text(c.$2),
          findsWidgets,
          reason: 'expected "${c.$2}" on screen after ${c.$1}. ${j.why}',
        );
        expect(
          find.byKey(const Key('knock-waiting')),
          findsNothing,
          reason: 'a refusal is not a pending knock. ${j.why}',
        );
        await j.finish();
      });
    }
  });

  group('layout', () {
    testWidgets('the waiting card fits 320 dp at text scale 2.0', (
      tester,
    ) async {
      for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
        final _Join j = await _Join.open(
          tester,
          'layout.waiting.${locale.languageCode}',
          locale: locale,
          width: 320,
          textScale: 2.0,
        );
        await j.typeAndJoin();
        await j.knockPending();
        expect(
          tester.takeException(),
          isNull,
          reason: 'expected no overflow. ${j.why}',
        );
        expect(
          find.byKey(const Key('knock-waiting')),
          findsOneWidget,
          reason: j.why,
        );
        final Size size = tester.getSize(
          find.byKey(const Key('knock-waiting-cancel')),
        );
        expect(
          size.width >= 48 && size.height >= 48,
          isTrue,
          reason: 'expected Cancel >= 48 dp at scale 2, saw $size. ${j.why}',
        );
        await j.finish();
        await tester.pumpWidget(const SizedBox());
      }
    });
  });
}
