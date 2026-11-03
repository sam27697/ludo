// Proof for contract C-551
// (work/ludo/orders/C-551-start-with-noun-and-waiting-marks.md), written from
// the contract alone: D1 the host's end card start button names what it
// counts, D2 the three docked waiting lines in the lobby carry a still
// hourglass mark.
//
// D1 is driven through GameScreen the way test/rematch_client_test.dart
// reaches the host-forced start (a FINISHED room, a rematch with two or
// three seats ready, one seat still out) and checked three ways: the exact
// ICU strings in both arb files, the generated lookups, and the Text the
// host actually sees. D2 mounts LobbyScreen the way
// test/lobby_seat_cards_test.dart does: a real RoomController over
// FakeTransport (test/net/fake_transport.dart, read-only here), one mount
// per case. Nothing here uses pumpAndSettle: the mark is static by
// contract, and a mark that animated would hang the lobby suites.
//
// The four lines:
//   guest-short  a guest in a room short of full, lobby-waiting
//   guest-full   a guest in a full room, lobby-waiting
//   host-short   the host short of full, lobby-waiting
//   rematch      lobby-rematch-waiting (a rematch lobby, I have accepted)
//
// Ambiguities, reported rather than invented around:
//
//   1. D2 says "the same string" for lobby-rematch-waiting but names no
//      string. The cases pin the three lobby-waiting strings to
//      lobbyWaitingForPlayers / lobbyWaitingForHost and, for the rematch
//      line, only that the Text is non-empty and that its semantics label
//      is that same string once.
//
//   2. D2 says "the same textAlign" and nothing here can know the old value
//      without reading the old source, so textAlign is not asserted.
//
//   3. "Excluded from semantics" is proved by behaviour: the semantics node
//      that carries the line has exactly the line's own text, once, and no
//      other words. An Icon with no semanticLabel adds no node on its own, so
//      the case also fails when the mark is missing (its first assertion),
//      which keeps it red until the mark exists.
//
//   4. The gap is read as a SizedBox of width kSpace2 that is a direct child
//      of the Row, between the child holding the mark and the child holding
//      the Text. An implementation that spaces with padding or a Gap widget
//      fails that one assertion and nothing else.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart' show LudoColors, kSpace2;
import 'package:path/path.dart' as p;

import 'net/fake_transport.dart';

const String _testUrl = 'wss://c551-test.invalid/ws';

const Key _waitingKey = Key('lobby-waiting');
const Key _rematchWaitingKey = Key('lobby-rematch-waiting');
const Key _startKey = Key('lobby-start-button');
const Key _endStartKey = Key('end-card-rematch-start');

// --- frames and snapshots, copied from the sibling suites -------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'c551-srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;

String _frame({
  required String type,
  String? re,
  Map<String, Object?> data = const <String, Object?>{},
}) => jsonEncode(<String, Object?>{
  'v': 1,
  't': type,
  'id': _nextServerId(),
  're': ?re,
  'd': data,
});

Map<String, Object?> _seatJson(
  int seat, {
  String name = '',
  bool connected = true,
}) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': connected,
  'tokens': <int>[-1, -1, -1, -1],
  'client_seed': null,
  'seed_origin': null,
};

List<Map<String, Object?>> _seats(int count) =>
    List<Map<String, Object?>>.generate(
      count,
      (int i) => _seatJson(i, name: 'p$i'),
    );

Map<String, Object?> _roomJson({
  String state = 'LOBBY',
  int hostSeat = 0,
  required int players,
  required List<Map<String, Object?>> seats,
  int? winner,
  Map<String, Object?>? rematch,
  int seq = 1,
}) => <String, Object?>{
  'code': 'ABC234',
  'state': state,
  'host_seat': hostSeat,
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
  'seats': seats,
  'turn': null,
  'winner': winner,
  'rematch': rematch,
  'seq': seq,
};

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];
  final List<Uri> calls = <Uri>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    calls.add(url);
    if (_queue.isEmpty) {
      throw StateError(
        '_Connector: connect() call #${calls.length} has no transport '
        'queued; the fixture is broken, not the code under test',
      );
    }
    return _queue.removeAt(0);
  }
}

RoomController _newController(_Connector connector) =>
    RoomController(serverUrl: Uri.parse(_testUrl), connect: connector.call);

Widget _harness(Widget child, {Locale locale = const Locale('en')}) {
  return MaterialApp(
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: child,
  );
}

// --- D1 fixtures: a FINISHED room with a partly-ready rematch ----------------

/// Mounts GameScreen as the host of a [seatCount]-seat room whose game just
/// finished, then pushes a rematch with [ready] seats accepted. The host's
/// end-card-rematch-start button is expected on screen afterwards.
Future<AppLocalizations> _mountHostEndCard(
  WidgetTester tester, {
  required int seatCount,
  required List<int> ready,
  required Locale locale,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = _newController(connector);
  addTearDown(controller.dispose);

  final Future<void> future = controller.createRoom(
    name: 'p0',
    players: seatCount,
  );
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  final String id = _idOf(transport.sentRaw.last);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': 0, 'seat_token': 'tok-0'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: id,
      data: _roomJson(
        state: 'FINISHED',
        players: seatCount,
        seats: _seats(seatCount),
        winner: 0,
      ),
    ),
  );
  await future;

  await tester.pumpWidget(
    _harness(GameScreen(controller: controller), locale: locale),
  );
  await tester.pump();
  for (int step = 0; step < ready.length; step++) {
    transport.pushText(
      _frame(
        type: 'room',
        data: _roomJson(
          state: 'FINISHED',
          players: seatCount,
          seats: _seats(seatCount),
          winner: 0,
          rematch: <String, Object?>{
            'by': 0,
            'ready': ready.sublist(0, step + 1),
          },
          seq: 2 + step,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }
  expect(
    controller.room!.rematch?.ready,
    ready,
    reason: 'fixture: the rematch must show ready seats $ready',
  );
  expect(controller.isHost, isTrue, reason: 'fixture: seat 0 is the host');
  return AppLocalizations.of(tester.element(find.byType(GameScreen)));
}

String _textUnder(WidgetTester tester, Finder root) {
  final Finder texts = find.descendant(of: root, matching: find.byType(Text));
  return tester
      .widgetList<Text>(texts)
      .map((Text t) => t.data ?? t.textSpan?.toPlainText() ?? '')
      .join('|');
}

// --- D2 fixtures: the docked waiting lines -----------------------------------

class _Line {
  const _Line(this.name, this.key);

  final String name;
  final Key key;
}

const _Line _guestShort = _Line('guest, room short of full', _waitingKey);
const _Line _guestFull = _Line('guest, full room', _waitingKey);
const _Line _hostShort = _Line('host, room short of full', _waitingKey);
const _Line _rematch = _Line('rematch waiting', _rematchWaitingKey);

/// Mounts LobbyScreen as [mySeat] and lands the room snapshot, the way
/// test/lobby_seat_cards_test.dart's own helper does.
Future<RoomController> _mountLobby(
  WidgetTester tester, {
  required int mySeat,
  required int players,
  required List<Map<String, Object?>> seats,
  Map<String, Object?>? rematch,
  required Locale locale,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = _newController(connector);
  addTearDown(controller.dispose);

  final bool amHost = mySeat == 0;
  await tester.pumpWidget(
    _harness(
      LobbyScreen(
        controller: controller,
        action: amHost ? LobbyAction.create : LobbyAction.join,
        code: amHost ? null : 'ABC234',
        playerName: 'Me',
        players: players,
      ),
      locale: locale,
    ),
  );
  await tester.pump();
  final String id = _idOf(transport.sentRaw.last);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': mySeat, 'seat_token': 'tok-$mySeat'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: id,
      data: _roomJson(players: players, seats: seats, rematch: rematch),
    ),
  );
  await tester.pump();
  await tester.pump();
  expect(
    controller.phase,
    RoomPhase.connected,
    reason:
        'fixture: the controller must reach connected; is ${controller.phase}',
  );
  return controller;
}

/// Mounts [line] and returns the string the line must read.
Future<String> _mountLine(
  WidgetTester tester,
  _Line line,
  Locale locale,
) async {
  switch (line) {
    case _guestShort:
      await _mountLobby(
        tester,
        mySeat: 1,
        players: 4,
        seats: _seats(2),
        locale: locale,
      );
    case _guestFull:
      await _mountLobby(
        tester,
        mySeat: 1,
        players: 2,
        seats: _seats(2),
        locale: locale,
      );
    case _hostShort:
      await _mountLobby(
        tester,
        mySeat: 0,
        players: 4,
        seats: _seats(2),
        locale: locale,
      );
    case _rematch:
      await _mountLobby(
        tester,
        mySeat: 0,
        players: 4,
        seats: <Map<String, Object?>>[
          _seatJson(0, name: 'Priya'),
          _seatJson(1, name: 'Karim'),
          _seatJson(2, name: 'Lina'),
          _seatJson(3, name: 'Omar', connected: false),
        ],
        rematch: <String, Object?>{
          'by': 1,
          'ready': <int>[0],
        },
        locale: locale,
      );
    default:
      fail('unknown line ${line.name}');
  }
  final AppLocalizations loc = AppLocalizations.of(
    tester.element(find.byType(LobbyScreen)),
  );
  expect(
    find.byKey(line.key),
    findsOneWidget,
    reason:
        'fixture: ${line.name} (${locale.languageCode}) must show '
        '${line.key}; it is not on screen',
  );
  final Text text = tester.widget<Text>(find.byKey(line.key));
  if (line == _guestShort || line == _hostShort) {
    return loc.lobbyWaitingForPlayers(2, 4);
  }
  if (line == _guestFull) {
    return loc.lobbyWaitingForHost;
  }
  return text.data ?? '';
}

String _why(_Line line, Locale locale) =>
    'C-551 D2, ${line.name}, ${locale.languageCode}';

final Finder _hourglass = find.byIcon(Icons.hourglass_top_rounded);

/// The Row the keyed Text sits in and the one hourglass directly in it. Fails
/// with the scenario in [why] when the Text has no Row, the Row has no mark,
/// or the mark sits in some deeper Row of its own.
(Element, Finder) _markIn(WidgetTester tester, Finder text, String why) {
  final List<Element> rows = find
      .ancestor(of: text, matching: find.byType(Row))
      .evaluate()
      .toList();
  if (rows.isEmpty) {
    fail('$why: the keyed Text sits in no Row, so it has no mark beside it');
  }
  final Element row = rows.first;
  final Finder rowFinder = find.byElementPredicate(
    (Element e) => identical(e, row),
    description: "the Text's Row",
  );
  final Finder mark = find.descendant(of: rowFinder, matching: _hourglass);
  final int n = mark.evaluate().length;
  if (n != 1) {
    fail(
      '$why: expected exactly one Icons.hourglass_top_rounded in the same '
      'Row as the keyed Text, found $n there and '
      '${_hourglass.evaluate().length} on screen',
    );
  }
  final Element markRow = find
      .ancestor(of: mark, matching: find.byType(Row))
      .evaluate()
      .first;
  if (!identical(markRow, row)) {
    fail('$why: the hourglass must sit directly in the Text\'s Row');
  }
  return (row, mark);
}

/// Collects the label of every semantics node under [node] whose rectangle
/// overlaps [area] into [out]. [to] maps [node]'s own
/// coordinates to the root's space, which is physical pixels.
void _labelsIn(SemanticsNode node, Matrix4 to, Rect area, List<String> out) {
  final Rect rect = MatrixUtils.transformRect(to, node.rect);
  if (node.label.isNotEmpty && area.overlaps(rect)) {
    out.add(node.label);
  }
  node.visitChildren((SemanticsNode child) {
    final Matrix4 next = to.clone();
    if (child.transform != null) {
      next.multiply(child.transform!);
    }
    _labelsIn(child, next, area, out);
    return true;
  });
}

int _count(String haystack, String needle) {
  if (needle.isEmpty) {
    return 0;
  }
  int n = 0;
  int from = 0;
  while (true) {
    final int at = haystack.indexOf(needle, from);
    if (at < 0) {
      return n;
    }
    n += 1;
    from = at + needle.length;
  }
}

void main() {
  // ===========================================================================
  // D1: "Start with {count}" names what it counts.
  // ===========================================================================
  group('C-551 D1: the arb strings', () {
    Map<String, dynamic> readArb(String name) {
      Directory dir = Directory.current;
      File file = File(p.join(dir.path, 'lib', 'l10n', name));
      if (!file.existsSync()) {
        dir = Directory(p.join(dir.path, 'packages', 'ludo_client'));
        file = File(p.join(dir.path, 'lib', 'l10n', name));
      }
      expect(file.existsSync(), isTrue, reason: 'expected ${file.path}');
      return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    }

    test('app_en.arb: endRematchStartReady is the plural with the noun', () {
      final Map<String, dynamic> en = readArb('app_en.arb');
      expect(
        en['endRematchStartReady'],
        '{count, plural, other{Start with {count} players}}',
        reason:
            'C-551 D1: en endRematchStartReady must be the ICU plural of the '
            'spec; got ${en['endRematchStartReady']}',
      );
    });

    test('app_ar.arb: endRematchStartReady has the =2 dual and the plural', () {
      final Map<String, dynamic> ar = readArb('app_ar.arb');
      expect(
        ar['endRematchStartReady'],
        '{count, plural, =2{ابدأ بلاعبَين} other{ابدأ بـ {count} لاعبين}}',
        reason:
            'C-551 D1: ar endRematchStartReady must be the ICU plural of the '
            'spec; got ${ar['endRematchStartReady']}',
      );
    });

    test('app_en.arb keeps the count placeholder block, typed int', () {
      final Map<String, dynamic> en = readArb('app_en.arb');
      final Object? meta = en['@endRematchStartReady'];
      expect(meta, isA<Map<String, dynamic>>());
      final Object? placeholders =
          (meta as Map<String, dynamic>)['placeholders'];
      expect(placeholders, isA<Map<String, dynamic>>());
      final Object? count = (placeholders as Map<String, dynamic>)['count'];
      expect(count, isA<Map<String, dynamic>>());
      expect(
        (count as Map<String, dynamic>)['type'],
        'int',
        reason: 'C-551 D1: the @endRematchStartReady count stays an int',
      );
    });

    test('the generated lookups agree with the arb, 2 3 and 4, en and ar', () {
      final AppLocalizations en = lookupAppLocalizations(const Locale('en'));
      final AppLocalizations ar = lookupAppLocalizations(const Locale('ar'));
      expect(
        en.endRematchStartReady(2),
        'Start with 2 players',
        reason: 'C-551 D1: generated en endRematchStartReady(2)',
      );
      expect(
        en.endRematchStartReady(3),
        'Start with 3 players',
        reason: 'C-551 D1: generated en endRematchStartReady(3)',
      );
      expect(
        en.endRematchStartReady(4),
        'Start with 4 players',
        reason: 'C-551 D1: generated en endRematchStartReady(4)',
      );
      expect(
        ar.endRematchStartReady(2),
        'ابدأ بلاعبَين',
        reason: 'C-551 D1: generated ar endRematchStartReady(2)',
      );
      expect(
        ar.endRematchStartReady(3),
        'ابدأ بـ 3 لاعبين',
        reason: 'C-551 D1: generated ar endRematchStartReady(3)',
      );
      expect(
        ar.endRematchStartReady(4),
        'ابدأ بـ 4 لاعبين',
        reason: 'C-551 D1: generated ar endRematchStartReady(4)',
      );
    });
  });

  group('C-551 D1: the host end card start button', () {
    final List<(String, Locale, int, List<int>, String)> cases =
        <(String, Locale, int, List<int>, String)>[
          (
            'en, 2 ready of 3',
            const Locale('en'),
            3,
            <int>[0, 1],
            'Start with 2 players',
          ),
          (
            'en, 3 ready of 4',
            const Locale('en'),
            4,
            <int>[0, 1, 2],
            'Start with 3 players',
          ),
          (
            'ar, 2 ready of 3',
            const Locale('ar'),
            3,
            <int>[0, 1],
            'ابدأ بلاعبَين',
          ),
          (
            'ar, 3 ready of 4',
            const Locale('ar'),
            4,
            <int>[0, 1, 2],
            'ابدأ بـ 3 لاعبين',
          ),
        ];
    for (final (String, Locale, int, List<int>, String) c in cases) {
      final (
        String name,
        Locale locale,
        int seatCount,
        List<int> ready,
        String expected,
      ) = c;
      testWidgets('$name: end-card-rematch-start reads "$expected"', (
        WidgetTester tester,
      ) async {
        await _mountHostEndCard(
          tester,
          seatCount: seatCount,
          ready: ready,
          locale: locale,
        );
        final Finder start = find.byKey(_endStartKey);
        expect(
          start,
          findsOneWidget,
          reason:
              'fixture: the host sees end-card-rematch-start with '
              '${ready.length} of $seatCount ready ($name)',
        );
        final String shown = _textUnder(tester, start);
        expect(
          shown,
          expected,
          reason:
              'C-551 D1 ($name): the start button must read "$expected" '
              '(count and noun); it shows "$shown". Scenario: host seat 0, '
              '$seatCount seats, ready $ready, locale ${locale.languageCode}',
        );
      });
    }
  });

  // ===========================================================================
  // D2: the docked waiting lines carry a still hourglass mark.
  // ===========================================================================
  for (final Locale locale in <Locale>[
    const Locale('en'),
    const Locale('ar'),
  ]) {
    for (final _Line line in <_Line>[
      _guestShort,
      _guestFull,
      _hostShort,
      _rematch,
    ]) {
      final String lang = locale.languageCode;

      testWidgets('D2 mark: ${line.name}, $lang: a leading hourglass in the '
          "Text's own Row, static and styled", (WidgetTester tester) async {
        final String expected = await _mountLine(tester, line, locale);
        final String why = _why(line, locale);
        final Finder text = find.byKey(line.key);
        final (Element row, Finder inRow) = _markIn(tester, text, why);

        final Row rowWidget = row.widget as Row;
        expect(
          rowWidget.mainAxisAlignment,
          MainAxisAlignment.center,
          reason: '$why: the row is centred',
        );

        final Icon icon = tester.widget<Icon>(inRow);
        final IconThemeData theme = IconTheme.of(tester.element(inRow));
        expect(icon.size ?? theme.size, 18, reason: '$why: icon size is 18');
        expect(
          icon.color ?? theme.color,
          LudoColors.inkMuted,
          reason: '$why: icon colour is LudoColors.inkMuted',
        );

        final List<Widget> kids = rowWidget.children;
        final int iconAt = kids.indexWhere(
          (Widget w) => find
              .descendant(of: find.byWidget(w), matching: _hourglass)
              .evaluate()
              .isNotEmpty,
        );
        final int textAt = kids.indexWhere(
          (Widget w) =>
              find
                  .descendant(of: find.byWidget(w), matching: text)
                  .evaluate()
                  .isNotEmpty ||
              w == tester.widget(text),
        );
        expect(iconAt, isNot(-1), reason: '$why: no Row child holds the mark');
        expect(textAt, isNot(-1), reason: '$why: no Row child holds the Text');
        final bool gap = kids
            .sublist(
              (iconAt < textAt ? iconAt : textAt) + 1,
              iconAt < textAt ? textAt : iconAt,
            )
            .any((Widget w) => w is SizedBox && w.width == kSpace2);
        expect(
          gap,
          isTrue,
          reason: '$why: a kSpace2 SizedBox gap between the mark and the Text',
        );

        expect(
          tester.widget<Text>(text).data,
          expected,
          reason: '$why: the Text keeps its key and its string',
        );
        expect(
          find.ancestor(
            of: inRow,
            matching: find.byWidgetPredicate(
              (Widget w) => w is RotationTransition || w is AnimatedRotation,
            ),
          ),
          findsNothing,
          reason: '$why: the mark is static, nothing may turn it',
        );
        final Rect before = tester.getRect(inRow);
        await tester.pump(const Duration(seconds: 5));
        expect(
          tester.getRect(inRow),
          before,
          reason: '$why: the mark must not move over five seconds',
        );
      });

      testWidgets('D2 order: ${line.name}, $lang: the mark comes before the '
          'Text in reading order', (WidgetTester tester) async {
        await _mountLine(tester, line, locale);
        final String why = _why(line, locale);
        final (Element _, Finder inRow) = _markIn(
          tester,
          find.byKey(line.key),
          why,
        );
        final double iconX = tester.getCenter(inRow).dx;
        final double textX = tester.getCenter(find.byKey(line.key)).dx;
        if (lang == 'ar') {
          expect(
            iconX,
            greaterThan(textX),
            reason:
                '$why: the row mirrors, the mark is right of the Text; '
                'mark centre x $iconX, Text centre x $textX',
          );
        } else {
          expect(
            iconX,
            lessThan(textX),
            reason:
                '$why: the mark is left of the Text; mark centre x $iconX, '
                'Text centre x $textX',
          );
        }
      });

      testWidgets('D2 semantics: ${line.name}, $lang: the line is read once, '
          'with no label for the mark', (WidgetTester tester) async {
        final SemanticsHandle handle = tester.ensureSemantics();
        try {
          final String expected = await _mountLine(tester, line, locale);
          final String why = _why(line, locale);
          final Element row = _markIn(tester, find.byKey(line.key), why).$1;
          final double dpr = tester.view.devicePixelRatio;
          final Rect logical = tester.getRect(
            find.byElementPredicate((Element e) => identical(e, row)),
          );
          final Rect area = Rect.fromLTRB(
            logical.left * dpr,
            logical.top * dpr,
            logical.right * dpr,
            logical.bottom * dpr,
          );
          SemanticsNode root = tester.getSemantics(find.byKey(line.key));
          while (root.parent != null) {
            root = root.parent!;
          }
          final List<String> labels = <String>[];
          _labelsIn(root, Matrix4.identity(), area, labels);
          final String joined = labels.join('\n');
          expect(
            _count(joined, expected),
            1,
            reason:
                '$why: the semantics label must carry "$expected" exactly '
                'once; labels were $labels',
          );
          final String rest = joined.replaceAll(expected, '').trim();
          expect(
            rest,
            isEmpty,
            reason:
                '$why: no words besides the line itself, the mark is excluded '
                'from semantics; extra "$rest" in $labels',
          );
        } finally {
          handle.dispose();
        }
      });
    }
  }

  // ===========================================================================
  // Guard: the host's full-room Start button is a button, not a waiting line.
  // ===========================================================================
  for (final Locale locale in <Locale>[
    const Locale('en'),
    const Locale('ar'),
  ]) {
    testWidgets('guard: the host\'s full-room Start button draws no hourglass, '
        '${locale.languageCode}', (WidgetTester tester) async {
      await _mountLobby(
        tester,
        mySeat: 0,
        players: 2,
        seats: _seats(2),
        locale: locale,
      );
      final Finder start = find.byKey(_startKey);
      expect(
        start,
        findsOneWidget,
        reason: 'fixture: a full room shows the host lobby-start-button',
      );
      expect(
        find.descendant(of: start, matching: _hourglass),
        findsNothing,
        reason: 'C-551 D2 guard: the Start button must not carry the mark',
      );
      expect(
        find.byKey(_waitingKey),
        findsNothing,
        reason: 'C-551 D2 guard: a full room shows the host no waiting line',
      );
    });
  }
}
