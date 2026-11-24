// C-692t: one digit system in the Arabic ban notice (X217).
//
// A real HomeScreen over a real RoomController on FakeTransport; the server's
// CODE_BANNED answer carries the ban. Rulings pinned from the order:
//   - in Arabic the notice holds no character of U+0660..U+0669 nor
//     U+06F0..U+06F9; the day, the time and the day counts are Latin digits
//   - the Arabic month name of the until date is spelled in Arabic
//   - English is exactly what it is today (expected text copied from the
//     output of the tree at 1f2d43a)
// Two until dates: a two-digit day (2028-01-15 10:42) and a single-digit day
// (2028-03-05 06:19), both local time. Scopes device (next_ms 7 days and 0)
// and network.
//
// Replay: flutter test test/c692_ban_date_digits_test.dart --plain-name '<id>'

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';
import 'support/home_flow.dart';

const Key _noticeKey = Key('code-ban-notice');
const Key _codeKey = Key('room-code-field');
const Key _joinKey = Key('join-room-button');

const String _code = 'K7M2QP';
const String _installA = 'Aa0_-Aa0_-Aa0_-Aa0_-Aa0_-Aa0_-Zz';
const int _day = 24 * 60 * 60 * 1000;

class _When {
  const _When(this.id, this.until, this.dayLatin, this.monthAr, this.timeLatin);
  final String id;
  final DateTime until;
  final String dayLatin;
  final String monthAr;
  final String timeLatin;
}

final List<_When> _whens = <_When>[
  _When('d15', DateTime(2028, 1, 15, 10, 42), '15', 'يناير', '10:42'),
  _When('d5', DateTime(2028, 3, 5, 6, 19), '5', 'مارس', '6:19'),
];

/// The English notice of today's tree, per scenario id, one string per Text,
/// joined by newlines. Copied from the probe run at 1f2d43a.
const Map<String, String> _enToday = <String, String>{
  'en.d15.device.next7': 'Typed room codes are blocked on this phone until Sat, Jan 15, 10:42 AM, because hosts kept turning it away.\nIf it happens again, the next block is 7 days.\nA link a friend sends still works.\n',
  'en.d15.device.next0': 'Typed room codes are blocked on this phone until Sat, Jan 15, 10:42 AM, because hosts kept turning it away.\nA link a friend sends still works.\n',
  'en.d15.network.next0': 'Typed room codes are paused on this network until Sat, Jan 15, 10:42 AM.\nA link a friend sends still works.\n',
  'en.d5.device.next7': 'Typed room codes are blocked on this phone until Sun, Mar 5, 6:19 AM, because hosts kept turning it away.\nIf it happens again, the next block is 7 days.\nA link a friend sends still works.\n',
  'en.d5.device.next0': 'Typed room codes are blocked on this phone until Sun, Mar 5, 6:19 AM, because hosts kept turning it away.\nA link a friend sends still works.\n',
  'en.d5.network.next0': 'Typed room codes are paused on this network until Sun, Mar 5, 6:19 AM.\nA link a friend sends still works.\n',
};

int _serverIdSeq = 0;
String _frame(String type, Map<String, Object?> data, {String? re}) {
  _serverIdSeq += 1;
  return jsonEncode(<String, Object?>{
    'v': 1,
    't': type,
    'id': 'c692d-srv-${_serverIdSeq.toString().padLeft(6, '0')}',
    're': ?re,
    'd': data,
  });
}

String _typeOf(String raw) =>
    (jsonDecode(raw) as Map<String, Object?>)['t']! as String;

bool _isIndicDigit(int r) =>
    (r >= 0x0660 && r <= 0x0669) || (r >= 0x06F0 && r <= 0x06F9);

String _hex(int r) => 'U+${r.toRadixString(16).toUpperCase().padLeft(4, '0')}';

Future<String> _noticeText(
  WidgetTester tester,
  String id,
  Locale locale,
  String scope,
  DateTime until,
  int nextMs,
) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    'install_id': _installA,
  });
  tester.view.physicalSize = const Size(800, 1800);
  tester.view.devicePixelRatio = 2;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final FakeTransport transport = FakeTransport();
  RoomController factory() => RoomController(
    serverUrl: Uri.parse('wss://c692-ban.invalid/ws'),
    connect: (Uri url) async => transport as WireTransport,
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
      home: HomeScreen(
        key: ValueKey<String>(id),
        onToggleLocale: () {},
        controllerFactory: factory,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  // Order 701: a name first (X226), then the code entry in the join sheet.
  await enterName(tester, oldDefaultName(locale.languageCode));
  await openCodeEntry(tester);
  await tester.enterText(find.byKey(_codeKey), _code);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.ensureVisible(find.byKey(_joinKey));
  await tester.pump();
  await tester.tap(find.byKey(_joinKey));
  await tester.pump();
  await tester.pump();
  for (int i = 0; i < 30 && transport.sentRaw.isEmpty; i += 1) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 100));
  }
  final String joinId =
      (jsonDecode(
            transport.sentRaw.lastWhere(
              (String r) => _typeOf(r) == 'join_room',
            ),
          ) as Map<String, Object?>)['id']!
          as String;
  transport.pushText(
    _frame('error', <String, Object?>{
      'code': 'CODE_BANNED',
      'message': 'code joins are blocked',
      'ban': <String, Object?>{
        'scope': scope,
        'until_ms': until.millisecondsSinceEpoch,
        'level': 1,
        'next_ms': nextMs,
      },
    }, re: joinId),
  );
  await tester.pump();
  await tester.pump();
  for (int i = 0; i < 48 && find.byKey(_noticeKey).evaluate().isEmpty; i += 1) {
    await tester.pump(const Duration(milliseconds: 250));
  }
  expect(
    find.byKey(_noticeKey),
    findsOneWidget,
    reason:
        'fixture: expected the ban notice after CODE_BANNED. scenario "$id". '
        "reproduce: flutter test test/c692_ban_date_digits_test.dart "
        "--plain-name '$id'",
  );
  final StringBuffer out = StringBuffer();
  for (final Element e
      in find
          .descendant(of: find.byKey(_noticeKey), matching: find.byType(Text))
          .evaluate()) {
    final Text t = e.widget as Text;
    out.writeln(t.data ?? t.textSpan?.toPlainText() ?? '');
  }
  await tester.pump(const Duration(seconds: 12));
  return out.toString();
}

void main() {
  const List<(String, int)> shapes = <(String, int)>[
    ('device', 7 * _day),
    ('device', 0),
    ('network', 0),
  ];

  group('ar: one digit system', () {
    for (final _When w in _whens) {
      for (final (String scope, int nextMs) in shapes) {
        final String id = 'ar.${w.id}.$scope.next${nextMs ~/ _day}';
        testWidgets(id, (tester) async {
          final String text = await _noticeText(
            tester,
            id,
            const Locale('ar'),
            scope,
            w.until,
            nextMs,
          );
          final String why =
              'scenario "$id" (until ${w.until}, scope $scope, next_ms '
              "$nextMs), text \"${text.replaceAll('\n', ' | ')}\". "
              "reproduce: flutter test test/c692_ban_date_digits_test.dart "
              "--plain-name '$id'";
          final List<String> bad = <String>[
            for (final int r in text.runes)
              if (_isIndicDigit(r)) _hex(r),
          ];
          expect(
            bad,
            isEmpty,
            reason:
                'expected no Arabic-Indic or Persian digit in the Arabic '
                'notice, found $bad. $why',
          );
          expect(
            RegExp('(^|[^0-9])${w.dayLatin}([^0-9]|\$)').hasMatch(text),
            isTrue,
            reason: 'expected the day ${w.dayLatin} in Latin digits. $why',
          );
          expect(
            text,
            contains(w.timeLatin),
            reason: 'expected the time ${w.timeLatin} in Latin digits. $why',
          );
          expect(
            text,
            contains(w.monthAr),
            reason: 'expected the Arabic month name ${w.monthAr}. $why',
          );
          if (scope == 'device' && nextMs > 0) {
            expect(
              text,
              contains('7'),
              reason: 'expected the 7 day count in Latin digits. $why',
            );
          }
        });
      }
    }
  });

  group('en: unchanged from today', () {
    for (final _When w in _whens) {
      for (final (String scope, int nextMs) in shapes) {
        final String id = 'en.${w.id}.$scope.next${nextMs ~/ _day}';
        testWidgets(id, (tester) async {
          final String text = await _noticeText(
            tester,
            id,
            const Locale('en'),
            scope,
            w.until,
            nextMs,
          );
          expect(
            text,
            _enToday[id],
            reason:
                'expected the English notice unchanged. scenario "$id". '
                "reproduce: flutter test test/c692_ban_date_digits_test.dart "
                "--plain-name '$id'",
          );
        });
      }
    }
  });
}
