// C-686t: the code-ban notice, docs/PROTOCOL.md section 32 items 9 and 12 and
// the order's goal 4 and 5.
//
// A real HomeScreen over a real RoomController on FakeTransport. The join is a
// typed code on the home screen; the server's answers are pushed as frames:
//   - a code join answered `CODE_BANNED` with `ban` shows the notice on home
//   - scope "device": the local date and time of `until_ms`, and the days of
//     `next_ms`; when `next_ms` is 0 there is no next-step line at all
//   - scope "network": the local time of `until_ms`, no days
//   - always one line that a friend's link still works
//   - red mark plus text (a RefusalMark or an Icon), never colour alone
//   - dismissible; the Join action stays enabled; another try gets the notice
//     again from the same answer
//   - `knock_failed` (rejected) and `kicked` WITH `ban` show the same notice
//     once on the screen the player lands on, in addition to today's line;
//     the same frames WITHOUT `ban` show none
//   - at 320 dp and text scale 2.0, en and ar, no overflow
//
// Names assumed (the lib hand may not have used them; the master rules):
//   Key('code-ban-notice')          the notice card, one widget when shown
//   Key('code-ban-notice-dismiss')  its close control, >= 48 dp
//   the notice holds its text in Text widgets and a RefusalMark or an Icon
//   the English notice says "link" (the friend's link line)
// The text itself is never compared to a literal: the date, time and day
// count are read from the visible digits (Arabic-Indic digits folded to Latin).
//
// Replay: flutter test test/c686_ban_notice_test.dart --plain-name '<id>'

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart' show LobbyScreen;
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/refusal_mark.dart' show RefusalMark;
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';
import 'support/home_flow.dart';

const Key _noticeKey = Key('code-ban-notice');
const Key _dismissKey = Key('code-ban-notice-dismiss');
const Key _codeKey = Key('room-code-field');
const Key _joinKey = Key('join-room-button');

const String _code = 'K7M2QP';
const String _installA = 'Aa0_-Aa0_-Aa0_-Aa0_-Aa0_-Aa0_-Zz';
const int _day = 24 * 60 * 60 * 1000;

/// Chosen so no digit run of the date or time contains "7" or "30": the day
/// counts below are found by those digits.
final DateTime _until = DateTime(2028, 1, 15, 10, 42);
final int _untilMs = _until.millisecondsSinceEpoch;

int _serverIdSeq = 0;
String _frame(String type, Map<String, Object?> data, {String? re}) {
  _serverIdSeq += 1;
  return jsonEncode(<String, Object?>{
    'v': 1,
    't': type,
    'id': 'c686b-srv-${_serverIdSeq.toString().padLeft(6, '0')}',
    're': ?re,
    'd': data,
  });
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;
String _typeOf(String raw) => _decode(raw)['t']! as String;

Map<String, Object?> _ban(
  String scope, {
  int? untilMs,
  int level = 1,
  int nextMs = 7 * _day,
}) => <String, Object?>{
  'scope': scope,
  'until_ms': untilMs ?? _untilMs,
  'level': level,
  'next_ms': nextMs,
};

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
  'link_id': 't5k2q9a-x7m3pd',
  'guest_approval': false,
  'knocks': const <Object?>[],
};

String _latinDigits(String s) {
  final StringBuffer out = StringBuffer();
  for (final int unit in s.runes) {
    if (unit >= 0x0660 && unit <= 0x0669) {
      out.writeCharCode(0x30 + unit - 0x0660);
    } else if (unit >= 0x06F0 && unit <= 0x06F9) {
      out.writeCharCode(0x30 + unit - 0x06F0);
    } else {
      out.writeCharCode(unit);
    }
  }
  return out.toString();
}

bool _isArabic(String s) => RegExp(r'[؀-ۿ]').hasMatch(s);

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
      "reproduce: flutter test test/c686_ban_notice_test.dart --plain-name '$id'";

  static Future<_Join> open(
    WidgetTester tester,
    String id, {
    Locale locale = const Locale('en'),
    double width = 400,
    double height = 900,
    double textScale = 1.0,
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'install_id': _installA,
    });
    tester.view.physicalSize = Size(width * 2, height * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final _Join j = _Join(id, tester);
    final List<FakeTransport> queue = <FakeTransport>[
      for (int i = 0; i < 3; i += 1) FakeTransport(),
    ];
    RoomController factory() => RoomController(
      serverUrl: Uri.parse('wss://c686-ban.invalid/ws'),
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
        home: HomeScreen(
          key: ValueKey<String>(id),
          onToggleLocale: () {},
          controllerFactory: factory,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    // Order 701 (X226): a join needs a name; the default the old field held.
    await enterName(tester, oldDefaultName(locale.languageCode));
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

  bool get noticeShown => find.byKey(_noticeKey).evaluate().isNotEmpty;

  /// Every visible string inside the notice, digits folded to Latin.
  String noticeText() {
    final Finder notice = find.byKey(_noticeKey);
    expect(
      notice,
      findsOneWidget,
      reason: 'expected exactly one code-ban-notice. $why',
    );
    final StringBuffer out = StringBuffer();
    for (final Element e
        in find
            .descendant(of: notice, matching: find.byType(Text))
            .evaluate()) {
      final Text t = e.widget as Text;
      out.writeln(t.data ?? t.textSpan?.toPlainText() ?? '');
    }
    return _latinDigits(out.toString());
  }

  int get joinCount => transports
      .expand((FakeTransport t) => t.sentRaw)
      .where((String r) => _typeOf(r) == 'join_room')
      .length;

  Future<void> tapJoin() async {
    await tester.ensureVisible(find.byKey(_joinKey));
    await tester.pump();
    await tester.tap(find.byKey(_joinKey));
    await tester.pump();
    await tester.pump();
  }

  Future<void> typeAndJoin() async {
    // Order 701: the code field is behind the join sheet's code tile.
    await openCodeEntry(tester);
    await tester.enterText(find.byKey(_codeKey), _code);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final int before = joinCount;
    await tapJoin();
    for (int i = 0; i < 30 && joinCount == before; i += 1) {
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      joinCount,
      before + 1,
      reason: 'fixture: expected one more join_room to be sent. $why',
    );
  }

  String get joinId {
    final String raw = transport.sentRaw.lastWhere(
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

  Future<void> codeBanned(Map<String, Object?>? ban) =>
      push('error', <String, Object?>{
        'code': 'CODE_BANNED',
        'message': 'code joins are blocked',
        'ban': ?ban,
      }, reply: true);

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

  // Order 701: the code field is no longer on home itself; home is the
  // screen that holds join-game-button (with or without its sheet up).
  bool get onHome =>
      find.byKey(joinGameButtonKey).evaluate().isNotEmpty &&
      find.byKey(const Key('knock-waiting')).evaluate().isEmpty &&
      find.byType(LobbyScreen, skipOffstage: false).evaluate().isEmpty;

  bool? get joinEnabled {
    final Finder join = find.byKey(_joinKey);
    if (join.evaluate().isEmpty) {
      return null;
    }
    final Widget w = tester.widget(join);
    if (w is ButtonStyleButton) {
      return w.onPressed != null;
    }
    final Finder inner = find.descendant(
      of: join,
      matching: find.byWidgetPredicate((Widget x) => x is ButtonStyleButton),
    );
    if (inner.evaluate().isEmpty) {
      return true;
    }
    return (tester.widget(inner.first) as ButtonStyleButton).onPressed != null;
  }

  Future<void> finish() async {
    await tester.pump(const Duration(seconds: 12));
  }
}

/// Opens, joins the typed code, answers CODE_BANNED and waits for the notice.
Future<_Join> _banned(
  WidgetTester tester,
  String id,
  Map<String, Object?> ban, {
  Locale locale = const Locale('en'),
  double width = 400,
  double height = 900,
  double textScale = 1.0,
}) async {
  final _Join j = await _Join.open(
    tester,
    id,
    locale: locale,
    width: width,
    height: height,
    textScale: textScale,
  );
  await j.typeAndJoin();
  await j.codeBanned(ban);
  expect(
    await j.waitFor(() => j.noticeShown),
    isTrue,
    reason: 'expected the ban notice after CODE_BANNED with $ban. ${j.why}',
  );
  return j;
}

void main() {
  group('CODE_BANNED, device scope', () {
    testWidgets('en: until date and time, the next step in days, a link line', (
      tester,
    ) async {
      final _Join j = await _banned(
        tester,
        'device.en',
        _ban('device', level: 1, nextMs: 7 * _day),
      );
      expect(j.onHome, isTrue, reason: 'expected to be on home. ${j.why}');
      final String text = j.noticeText();
      expect(
        text,
        contains('15'),
        reason: 'expected the day of the until date (15) in "$text". ${j.why}',
      );
      expect(
        text,
        contains('42'),
        reason:
            'expected the minutes of the until time (42) in "$text". ${j.why}',
      );
      expect(
        text,
        contains('7'),
        reason: 'expected the next step of 7 days in "$text". ${j.why}',
      );
      expect(
        text.toLowerCase(),
        contains('link'),
        reason:
            'expected the line that a link still works in "$text". ${j.why}',
      );
      expect(
        _isArabic(text),
        isFalse,
        reason: 'expected English only in "$text". ${j.why}',
      );
      await j.finish();
    });

    testWidgets('en: 30 days next step reads 30', (tester) async {
      final _Join j = await _banned(
        tester,
        'device.en.30',
        _ban('device', level: 2, nextMs: 30 * _day),
      );
      expect(
        j.noticeText(),
        contains('30'),
        reason: 'expected 30 days in "${j.noticeText()}". ${j.why}',
      );
      await j.finish();
    });

    testWidgets('en: 730 days next step reads 730', (tester) async {
      final _Join j = await _banned(
        tester,
        'device.en.730',
        _ban('device', level: 3, nextMs: 730 * _day),
      );
      expect(
        j.noticeText(),
        contains('730'),
        reason: 'expected 730 days in "${j.noticeText()}". ${j.why}',
      );
      await j.finish();
    });

    testWidgets('en: next_ms 0 says nothing about a next block', (
      tester,
    ) async {
      final _Join withNext = await _banned(
        tester,
        'device.en.next',
        _ban('device', level: 2, nextMs: 30 * _day),
      );
      final String long = withNext.noticeText();
      await withNext.finish();

      final _Join j = await _banned(
        tester,
        'device.en.zero',
        _ban('device', level: 4, nextMs: 0),
      );
      final String text = j.noticeText();
      expect(
        text,
        isNot(contains('30')),
        reason:
            'expected no day count when next_ms is 0, saw "$text". ${j.why}',
      );
      expect(
        text,
        isNot(contains('0 day')),
        reason: 'expected no "0 days" line, saw "$text". ${j.why}',
      );
      expect(
        text.trim().split('\n').where((String l) => l.trim().isNotEmpty).length,
        lessThan(
          long
              .trim()
              .split('\n')
              .where((String l) => l.trim().isNotEmpty)
              .length,
        ),
        reason:
            'expected one line fewer without a next step. with next: "$long"; '
            'without: "$text". ${j.why}',
      );
      expect(
        text,
        contains('42'),
        reason: 'the until time is still said, "$text". ${j.why}',
      );
      await j.finish();
    });

    testWidgets('ar: Arabic text with the date, time and days', (tester) async {
      final _Join j = await _banned(
        tester,
        'device.ar',
        _ban('device', level: 2, nextMs: 30 * _day),
        locale: const Locale('ar'),
      );
      final String text = j.noticeText();
      expect(
        _isArabic(text),
        isTrue,
        reason: 'expected Arabic text, saw "$text". ${j.why}',
      );
      expect(text, contains('15'), reason: 'day 15 in "$text". ${j.why}');
      expect(text, contains('42'), reason: 'minutes 42 in "$text". ${j.why}');
      expect(text, contains('30'), reason: '30 days in "$text". ${j.why}');
      await j.finish();
    });

    testWidgets('ar: next_ms 0 has no day count', (tester) async {
      final _Join j = await _banned(
        tester,
        'device.ar.zero',
        _ban('device', level: 4, nextMs: 0),
        locale: const Locale('ar'),
      );
      final String text = j.noticeText();
      expect(
        text,
        isNot(contains('30')),
        reason: 'expected no day count, saw "$text". ${j.why}',
      );
      expect(_isArabic(text), isTrue, reason: 'Arabic text. ${j.why}');
      await j.finish();
    });
  });

  group('CODE_BANNED, network scope', () {
    testWidgets('en: the until time, no days, a link line', (tester) async {
      final _Join j = await _banned(
        tester,
        'network.en',
        _ban('network', level: 0, nextMs: 0),
      );
      final String text = j.noticeText();
      expect(text, contains('42'), reason: 'minutes 42 in "$text". ${j.why}');
      expect(
        text,
        isNot(contains('30')),
        reason: 'no day count on a network pause, saw "$text". ${j.why}',
      );
      expect(
        text.toLowerCase(),
        contains('link'),
        reason: 'expected the link line in "$text". ${j.why}',
      );
      expect(_isArabic(text), isFalse, reason: 'English only. ${j.why}');
      await j.finish();
    });

    testWidgets('en: the network notice is worded apart from the device one', (
      tester,
    ) async {
      final _Join d = await _banned(
        tester,
        'network.vs.device.d',
        _ban('device', level: 1, nextMs: 7 * _day),
      );
      final String device = d.noticeText();
      await d.finish();
      final _Join n = await _banned(
        tester,
        'network.vs.device.n',
        _ban('network', level: 0, nextMs: 0),
      );
      final String network = n.noticeText();
      expect(
        network,
        isNot(equals(device)),
        reason:
            'expected different wording for the two scopes; both read '
            '"$network". ${n.why}',
      );
      await n.finish();
    });

    testWidgets('ar: Arabic text with the time', (tester) async {
      final _Join j = await _banned(
        tester,
        'network.ar',
        _ban('network', level: 0, nextMs: 0),
        locale: const Locale('ar'),
      );
      final String text = j.noticeText();
      expect(_isArabic(text), isTrue, reason: 'Arabic text "$text". ${j.why}');
      expect(text, contains('42'), reason: 'minutes 42 in "$text". ${j.why}');
      expect(text, isNot(contains('30')), reason: 'no days. ${j.why}');
      await j.finish();
    });
  });

  group('the notice as a card', () {
    testWidgets(
      'a red mark or an icon sits with the text, never colour alone',
      (tester) async {
        final _Join j = await _banned(tester, 'card.mark', _ban('device'));
        final Finder notice = find.byKey(_noticeKey);
        final bool hasMark =
            find
                .descendant(of: notice, matching: find.byType(RefusalMark))
                .evaluate()
                .isNotEmpty ||
            find
                .descendant(of: notice, matching: find.byType(Icon))
                .evaluate()
                .isNotEmpty;
        expect(
          hasMark,
          isTrue,
          reason:
              'expected a RefusalMark or an Icon inside the notice. ${j.why}',
        );
        expect(
          find.descendant(of: notice, matching: find.byType(Text)),
          findsWidgets,
          reason: 'expected text inside the notice. ${j.why}',
        );
        await j.finish();
      },
    );

    testWidgets('it is dismissible, by a 48 dp control', (tester) async {
      final _Join j = await _banned(tester, 'card.dismiss', _ban('device'));
      final Finder dismiss = find.byKey(_dismissKey);
      expect(
        dismiss,
        findsOneWidget,
        reason: 'expected a dismiss control. ${j.why}',
      );
      final Size size = tester.getSize(dismiss);
      expect(
        size.width >= 48 && size.height >= 48,
        isTrue,
        reason: 'expected the dismiss control >= 48 dp, saw $size. ${j.why}',
      );
      await tester.ensureVisible(dismiss);
      await tester.pump();
      await tester.tap(dismiss);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        j.noticeShown,
        isFalse,
        reason: 'expected the notice gone after dismiss. ${j.why}',
      );
      await j.finish();
    });

    testWidgets('Join stays enabled and the typed code stays', (tester) async {
      final _Join j = await _banned(tester, 'card.join', _ban('device'));
      expect(
        j.joinEnabled,
        isTrue,
        reason: 'expected Join enabled under a ban (a link works). ${j.why}',
      );
      expect(
        tester.widget<TextField>(find.byKey(_codeKey)).controller!.text,
        _code,
        reason: 'expected the typed code to stay. ${j.why}',
      );
      await j.finish();
    });

    testWidgets('another try sends another join and gets the notice again', (
      tester,
    ) async {
      final _Join j = await _banned(tester, 'card.retry', _ban('device'));
      expect(j.joinCount, 1, reason: 'fixture: one join so far. ${j.why}');
      await tester.tap(find.byKey(_dismissKey));
      await tester.pump(const Duration(milliseconds: 600));
      expect(j.noticeShown, isFalse, reason: 'dismissed. ${j.why}');
      await j.tapJoin();
      for (int i = 0; i < 30 && j.joinCount < 2; i += 1) {
        await tester.runAsync(() => pumpEventQueue());
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        j.joinCount,
        2,
        reason: 'expected a second join_room on another try. ${j.why}',
      );
      await j.codeBanned(_ban('device'));
      expect(
        await j.waitFor(() => j.noticeShown),
        isTrue,
        reason: 'expected the notice again from the same answer. ${j.why}',
      );
      expect(find.byKey(_noticeKey), findsOneWidget, reason: j.why);
      await j.finish();
    });
  });

  group('the notice at the moment of the strike', () {
    Future<_Join> knockRejected(
      WidgetTester tester,
      String id, {
      Map<String, Object?>? ban,
      Locale locale = const Locale('en'),
    }) async {
      final _Join j = await _Join.open(tester, id, locale: locale);
      await j.typeAndJoin();
      await j.push('knock_pending', <String, Object?>{
        'knock_id': 'kn-me',
        'expires_ms': 60000,
      }, reply: true);
      await j.push('knock_failed', <String, Object?>{
        'knock_id': 'kn-me',
        'outcome': 'rejected',
        'ban': ?ban,
      });
      expect(await j.waitFor(() => j.onHome), isTrue, reason: 'home. ${j.why}');
      await tester.pump(const Duration(milliseconds: 600));
      return j;
    }

    Future<_Join> kicked(
      WidgetTester tester,
      String id, {
      Map<String, Object?>? ban,
      Locale locale = const Locale('en'),
    }) async {
      final _Join j = await _Join.open(tester, id, locale: locale);
      await j.typeAndJoin();
      await j.push('seat_assigned', <String, Object?>{
        'seat': 1,
        'seat_token': 'tok-c686-k',
      });
      await j.push('room', _room(5), reply: true);
      await tester.pump(const Duration(seconds: 1));
      await j.push('kicked', <String, Object?>{'ban': ?ban});
      expect(await j.waitFor(() => j.onHome), isTrue, reason: 'home. ${j.why}');
      await tester.pump(const Duration(milliseconds: 600));
      return j;
    }

    testWidgets('knock_failed rejected with ban shows the notice once', (
      tester,
    ) async {
      final _Join j = await knockRejected(
        tester,
        'strike.knock.ban',
        ban: _ban('device', level: 1, nextMs: 7 * _day),
      );
      expect(
        find.byKey(_noticeKey),
        findsOneWidget,
        reason:
            'expected exactly one notice on home after the strike. ${j.why}',
      );
      final String text = j.noticeText();
      expect(text, contains('15'), reason: 'until date in "$text". ${j.why}');
      expect(
        text,
        contains('7'),
        reason: 'next step days in "$text". ${j.why}',
      );
      await j.finish();
    });

    testWidgets('knock_failed rejected without ban shows no notice', (
      tester,
    ) async {
      final _Join j = await knockRejected(tester, 'strike.knock.noban');
      expect(
        find.byKey(_noticeKey),
        findsNothing,
        reason: 'expected no notice when the frame carries no ban. ${j.why}',
      );
      await j.finish();
    });

    testWidgets(
      'knock_failed with ban keeps today\'s line and adds the notice',
      (tester) async {
        final _Join plain = await knockRejected(tester, 'strike.knock.base');
        final Set<String> base = plain.visibleTexts();
        await plain.finish();
        final _Join j = await knockRejected(
          tester,
          'strike.knock.both',
          ban: _ban('device'),
        );
        final Set<String> now = j.visibleTexts();
        final Set<String> lost = base.difference(now);
        expect(
          lost,
          isEmpty,
          reason:
              'expected every line of today\'s rejected screen to stay, lost '
              '$lost. ${j.why}',
        );
        expect(find.byKey(_noticeKey), findsOneWidget, reason: j.why);
        await j.finish();
      },
    );

    testWidgets('kicked with ban shows the notice once', (tester) async {
      final _Join j = await kicked(
        tester,
        'strike.kicked.ban',
        ban: _ban('device', level: 1, nextMs: 7 * _day),
      );
      expect(
        find.byKey(_noticeKey),
        findsOneWidget,
        reason: 'expected exactly one notice after a kick with ban. ${j.why}',
      );
      await j.finish();
    });

    testWidgets('kicked without ban shows no notice', (tester) async {
      final _Join j = await kicked(tester, 'strike.kicked.noban');
      expect(
        find.byKey(_noticeKey),
        findsNothing,
        reason: 'expected no notice when kicked carries no ban. ${j.why}',
      );
      await j.finish();
    });

    testWidgets('kicked with ban keeps today\'s line and adds the notice', (
      tester,
    ) async {
      final _Join plain = await kicked(tester, 'strike.kicked.base');
      final Set<String> base = plain.visibleTexts();
      await plain.finish();
      final _Join j = await kicked(
        tester,
        'strike.kicked.both',
        ban: _ban('device'),
      );
      final Set<String> lost = base.difference(j.visibleTexts());
      expect(
        lost,
        isEmpty,
        reason:
            'expected every line of today\'s kicked screen to stay, lost '
            '$lost. ${j.why}',
      );
      expect(find.byKey(_noticeKey), findsOneWidget, reason: j.why);
      await j.finish();
    });

    testWidgets('a dismissed strike notice does not come back with a new try', (
      tester,
    ) async {
      final _Join j = await knockRejected(
        tester,
        'strike.once',
        ban: _ban('device'),
      );
      await tester.tap(find.byKey(_dismissKey));
      await tester.pump(const Duration(milliseconds: 600));
      expect(j.noticeShown, isFalse, reason: 'dismissed. ${j.why}');
      // Order 701: the refused knock left the join sheet; a new try opens
      // the code entry again and types the code.
      await openCodeEntry(tester);
      await tester.enterText(find.byKey(_codeKey), _code);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await j.tapJoin();
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        j.noticeShown,
        isFalse,
        reason: 'expected the strike notice shown once only. ${j.why}',
      );
      await j.finish();
    });

    testWidgets('ar: the strike notice is Arabic', (tester) async {
      final _Join j = await knockRejected(
        tester,
        'strike.knock.ar',
        ban: _ban('device', level: 1, nextMs: 7 * _day),
        locale: const Locale('ar'),
      );
      expect(
        _isArabic(j.noticeText()),
        isTrue,
        reason: 'expected Arabic, saw "${j.noticeText()}". ${j.why}',
      );
      await j.finish();
    });
  });

  group('320 dp at text scale 2.0', () {
    for (final String lang in <String>['en', 'ar']) {
      for (final String scope in <String>['device', 'network']) {
        testWidgets('$lang $scope: no overflow, inside the width', (
          tester,
        ) async {
          final _Join j = await _banned(
            tester,
            'fit.$lang.$scope',
            scope == 'device'
                ? _ban('device', level: 3, nextMs: 730 * _day)
                : _ban('network', level: 0, nextMs: 0),
            locale: Locale(lang),
            width: 320,
            height: 640,
            textScale: 2.0,
          );
          await tester.ensureVisible(find.byKey(_noticeKey));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));
          expect(
            tester.takeException(),
            isNull,
            reason: 'expected no layout exception at 320 dp x2.0. ${j.why}',
          );
          final Rect rect = tester.getRect(find.byKey(_noticeKey));
          expect(
            rect.left >= 0 && rect.right <= 320,
            isTrue,
            reason:
                'expected the notice inside 0..320 dp, saw '
                '${rect.left}..${rect.right}. ${j.why}',
          );
          final Rect close = tester.getRect(find.byKey(_dismissKey));
          expect(
            close.left >= 0 && close.right <= 320,
            isTrue,
            reason:
                'expected the dismiss control inside 0..320 dp, saw '
                '${close.left}..${close.right}. ${j.why}',
          );
          for (final Element e
              in find
                  .descendant(
                    of: find.byKey(_noticeKey),
                    matching: find.byType(RichText),
                  )
                  .evaluate()) {
            final RenderParagraph p = e.renderObject! as RenderParagraph;
            expect(
              p.didExceedMaxLines,
              isFalse,
              reason: 'expected no clipped paragraph in the notice. ${j.why}',
            );
          }
          await j.finish();
        });
      }
    }
  });
}
