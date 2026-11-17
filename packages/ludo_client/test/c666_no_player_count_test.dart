// Proof for order C-666 (work/ludo/orders/666-no-player-count.md), D1 to D3:
// the home screen no longer asks how many players, Create always asks the
// server for a four-seat room, and the lobby decides what the host and the
// guests see from how many seats are taken, not from a chosen count.
// Written from the contract text, against no implementation of it.
//
// The new string lobbyWaitingForFriends does not exist on the base, so this
// file reads the waiting line through the English and Arabic texts the
// contract gives literally ("Waiting for friends to join", "عم نستنى أصحابك
// يفوتوا"), never through a generated getter. The strings that already exist
// (lobbyWaitingForHost, lobbyStartWithPresent, lobbyStartButton) are read
// through the generated localizations. The strings the contract removes
// (homePlayersQuestion, lobbyWaitingForPlayers) are matched by their literal
// old text, so this file compiles whether or not the getters are still
// generated. The removed PlayerCountIcon is matched by its runtime type
// name, so no import of its file is needed.
//
// HomeScreen and LobbyScreen are driven the way home_plain_test.dart and
// lobby_start_with_present_test.dart drive them: the real screens inside a
// MaterialApp with the app's delegates, a real RoomController over a
// FakeTransport (test/net/fake_transport.dart, read-only here). The idioms
// are copied by hand; nothing is imported across test files.
//
// Ambiguities, reported rather than invented around:
//
//   1. The contract names no key for the docked waiting line in the host
//      lobby; its prose says "no lobby-waiting" for 2 and 3 seated, which
//      reads as the existing key. The waiting-line cases find the line by
//      its text and also require the key lobby-waiting, the one key the
//      docked waiting line has always carried.
//   2. The chip's spoken label: D1 does not say whether it still carries a
//      count word. It is read here as the table name alone (the master
//      confirmed that for the committed implementation).
//   3. "The gap it leaves closes (no empty slot)" has no number. The case
//      reads it as: between the name field and Create there is less room
//      than a 48 dp control would need, so no row-sized hole is left.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart'
    show appSupportedLocales, buildAppTheme;
import 'package:ludo_client/src/deep_link.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/seat_card.dart' show OpenSeatCard;
import 'package:ludo_client/src/server_config.dart';
import 'package:ludo_client/src/session_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://c666-test.invalid/ws';

const Key _createKey = Key('create-room-button');
const Key _nameKey = Key('home-name-field');
const Key _lastTableKey = Key('home-last-table-chip');
const Key _startKey = Key('lobby-start-button');
const Key _startWithPresentKey = Key('lobby-start-with-present-button');
const Key _waitingKey = Key('lobby-waiting');

const String _friendsEn = 'Waiting for friends to join';
const String _friendsAr = 'عم نستنى أصحابك يفوتوا';
const String _questionEn = 'How many players?';
const String _questionAr = 'كم لاعب؟';
const String _oldWaitingEn = 'Waiting for players';
const String _oldWaitingAr = 'بانتظار اللاعبين';

const List<Locale> _locales = <Locale>[Locale('en'), Locale('ar')];

String _friends(Locale l) => l.languageCode == 'ar' ? _friendsAr : _friendsEn;
String _question(Locale l) =>
    l.languageCode == 'ar' ? _questionAr : _questionEn;
String _oldWaiting(Locale l) =>
    l.languageCode == 'ar' ? _oldWaitingAr : _oldWaitingEn;

/// What a failing case prints so it can be rerun. Every case is fully
/// deterministic (no random input, no wall clock), so the scenario name, the
/// locale and the surface are the whole seed.
String _repro(String scenario, Locale locale, [String surface = '390x844']) {
  return 'Reproduce: scenario "$scenario", locale ${locale.languageCode}, '
      'surface $surface, flutter test test/c666_no_player_count_test.dart '
      '--plain-name "$scenario". No random input is involved.';
}

// --- fonts (real ones for the fit cases; Ahem is far wider) ------------------

Future<void> _loadAppFonts() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final FontLoader poppins = FontLoader('Poppins');
  for (final String asset in const <String>[
    'fonts/Poppins-Regular.ttf',
    'fonts/Poppins-Medium.ttf',
    'fonts/Poppins-SemiBold.ttf',
    'fonts/Poppins-Bold.ttf',
  ]) {
    poppins.addFont(rootBundle.load(asset));
  }
  await poppins.load();
  final FontLoader arabic = FontLoader('Noto Sans Arabic');
  for (final String asset in const <String>[
    'fonts/NotoSansArabic-Regular.ttf',
    'fonts/NotoSansArabic-Bold.ttf',
  ]) {
    arabic.addFont(rootBundle.load(asset));
  }
  await arabic.load();
}

/// A from-scratch TextPainter measurement of [text] at [style], laid out with
/// no width limit.
double _naturalWidthOf(String text, TextStyle style, TextDirection direction) {
  final TextPainter probe = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: direction,
  )..layout();
  try {
    return probe.width;
  } finally {
    probe.dispose();
  }
}

// --- wire fixtures -------------------------------------------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;
String _idOf(String sentText) => _decode(sentText)['id']! as String;
String _typeOf(String sentText) => _decode(sentText)['t']! as String;
Map<String, Object?> _dataOf(String sentText) =>
    _decode(sentText)['d']! as Map<String, Object?>;

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

Map<String, Object?> _seatJson(int seat, {required String name}) =>
    <String, Object?>{
      'seat': seat,
      'name': name,
      'connected': true,
      'tokens': <int>[-1, -1, -1, -1],
      'client_seed': null,
      'seed_origin': null,
    };

/// [occupied] consecutive seats from 0, seat 0 the host.
List<Map<String, Object?>> _seats(int occupied, {List<String>? names}) =>
    List<Map<String, Object?>>.generate(
      occupied,
      (int i) => _seatJson(i, name: names == null ? 'p$i' : names[i]),
    );

Map<String, Object?> _roomJson({
  int players = 4,
  required List<Map<String, Object?>> seats,
  int seq = 1,
}) => <String, Object?>{
  'code': 'ABC234',
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
  'seats': seats,
  'turn': null,
  'winner': null,
  'seq': seq,
};

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    if (_queue.isEmpty) {
      throw StateError(
        '_Connector: connect() with no transport queued; the scenario is '
        'broken, not the code under test',
      );
    }
    return _queue.removeAt(0);
  }
}

// --- harness -------------------------------------------------------------------

class _LiveControllerFactory {
  final List<FakeTransport> transports = <FakeTransport>[];

  RoomController call() {
    return RoomController(
      serverUrl: Uri.parse(_testUrl),
      connect: (Uri url) async {
        final FakeTransport transport = FakeTransport();
        transports.add(transport);
        return transport;
      },
    );
  }
}

Widget _app(Locale locale, Widget home, {double textScale = 1.0}) {
  return MaterialApp(
    theme: buildAppTheme(),
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    builder: (BuildContext context, Widget? child) {
      if (textScale == 1.0) {
        return child!;
      }
      return MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      );
    },
    home: home,
  );
}

void _surface(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _mountHome(
  WidgetTester tester, {
  required Locale locale,
  RoomControllerFactory? controllerFactory,
  Size size = const Size(390, 844),
  double textScale = 1.0,
}) async {
  _surface(tester, size);
  await tester.pumpWidget(
    _app(
      locale,
      HomeScreen(
        onToggleLocale: () {},
        controllerFactory: controllerFactory ?? _LiveControllerFactory().call,
        initialLinkReader: noInitialLink,
        linkStream: noLinkStream,
      ),
      textScale: textScale,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pumpAndSettle();
}

/// Every string any RichText under [root] paints, Offstage subtrees
/// included; Icon is skipped (its RichText carries a glyph, not a string).
List<String> _paintedStrings([Element? root]) {
  final List<String> out = <String>[];
  void visit(Element element) {
    final Widget widget = element.widget;
    if (widget is Icon) {
      return;
    }
    if (widget is RichText) {
      out.add(widget.text.toPlainText(includeSemanticsLabels: false));
    }
    element.visitChildren(visit);
  }

  if (root == null) {
    WidgetsBinding.instance.rootElement!.visitChildren(visit);
  } else {
    visit(root);
  }
  return out;
}

Future<void> _scrollHomeToEnd(WidgetTester tester) async {
  final ScrollPosition position = Scrollable.of(
    tester.element(find.byKey(const Key('room-code-field'))),
  ).position;
  position.jumpTo(position.maxScrollExtent);
  await tester.pump();
}

/// Taps Create and returns the `d` of the one create_room frame sent.
Future<Map<String, Object?>> _tapCreateAndRead(
  WidgetTester tester,
  _LiveControllerFactory factory,
  String repro,
) async {
  await tester.ensureVisible(find.byKey(_createKey));
  await tester.tap(find.byKey(_createKey));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  expect(
    factory.transports,
    hasLength(1),
    reason: 'expected Create to open exactly one transport. $repro',
  );
  final List<Map<String, Object?>> sent = factory.transports.single.sentRaw
      .map(_decode)
      .toList();
  expect(sent.map((Map<String, Object?> f) => f['t']).toList(), <Object?>[
    'create_room',
  ], reason: 'expected exactly one create_room frame on the wire. $repro');
  return sent.single['d']! as Map<String, Object?>;
}

/// Lets the 10 s request timeout of an unanswered create run out so no timer
/// outlives the case.
Future<void> _drainRequestTimeout(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 11));
  await tester.pump();
}

bool _isPlayerCountIcon(Widget w) =>
    w.runtimeType.toString() == 'PlayerCountIcon';

class _Lobby {
  _Lobby(this.tester, this.controller, this.transport);

  final WidgetTester tester;
  final RoomController controller;
  final FakeTransport transport;
}

/// Mounts a LobbyScreen as the host (create) or as a guest (join) and
/// resolves it into a connected room of [players] seats with [seated] taken.
Future<_Lobby> _mountLobby(
  WidgetTester tester, {
  required Locale locale,
  required bool host,
  required int seated,
  int players = 4,
  List<String>? names,
  Size size = const Size(390, 844),
  double textScale = 1.0,
}) async {
  _surface(tester, size);
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    _app(
      locale,
      host
          ? LobbyScreen(
              controller: controller,
              action: LobbyAction.create,
              playerName: 'p0',
              players: players,
            )
          : LobbyScreen(
              controller: controller,
              action: LobbyAction.join,
              code: 'ABC234',
              playerName: 'p1',
            ),
      textScale: textScale,
    ),
  );
  await tester.pump();
  expect(
    transport.sentRaw,
    isNotEmpty,
    reason:
        'fixture: LobbyScreen.initState must have sent its create_room or '
        'join_room by now; nothing reached the transport',
  );
  final String requestId = _idOf(transport.sentRaw.last);
  final int mySeat = host ? 0 : 1;
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': mySeat, 'seat_token': 'tok-$mySeat'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: requestId,
      data: _roomJson(
        players: players,
        seats: _seats(seated, names: names),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  expect(
    controller.isHost,
    host,
    reason: 'fixture: the scenario must mount as the ${host ? '' : 'non-'}host',
  );
  expect(controller.room!.seats.length, seated, reason: 'fixture: seated');
  expect(controller.room!.players, players, reason: 'fixture: players');
  return _Lobby(tester, controller, transport);
}

/// A server push of a new room snapshot with [seated] seats taken.
Future<void> _pushRoom(
  _Lobby lobby, {
  required int seated,
  required int seq,
  int players = 4,
}) async {
  lobby.transport.pushText(
    _frame(
      type: 'room',
      data: _roomJson(players: players, seats: _seats(seated), seq: seq),
    ),
  );
  await lobby.tester.pump();
  await lobby.tester.pump();
}

AppLocalizations _loc(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(Scaffold).first));

/// The control set D2/D3 allow in an ordinary lobby, read off the tree.
void _expectLobbySet(
  WidgetTester tester, {
  required Locale locale,
  required String scenario,
  required bool waitingFriends,
  required bool waitingHost,
  required int? startWithPresent,
  required bool start,
  String surface = '390x844',
}) {
  final String repro = _repro(scenario, locale, surface);
  final AppLocalizations loc = _loc(tester);
  expect(
    find.text(_friends(locale)),
    waitingFriends ? findsOneWidget : findsNothing,
    reason:
        'expected the waiting-for-friends line "${_friends(locale)}" '
        '${waitingFriends ? 'once' : 'nowhere'}. $repro',
  );
  expect(
    find.text(loc.lobbyWaitingForHost),
    waitingHost ? findsOneWidget : findsNothing,
    reason:
        'expected the waiting-for-host line "${loc.lobbyWaitingForHost}" '
        '${waitingHost ? 'once' : 'nowhere'}. $repro',
  );
  expect(
    find.textContaining(_oldWaiting(locale)),
    findsNothing,
    reason:
        'expected the old "${_oldWaiting(locale)} (n of m)" line nowhere in '
        'an ordinary lobby. $repro',
  );
  expect(
    find.byKey(_waitingKey),
    waitingFriends || waitingHost ? findsOneWidget : findsNothing,
    reason:
        'expected the key lobby-waiting '
        '${waitingFriends || waitingHost ? 'once' : 'nowhere'}. $repro',
  );
  expect(
    find.byKey(_startKey),
    start ? findsOneWidget : findsNothing,
    reason: 'expected lobby-start-button ${start ? 'once' : 'nowhere'}. $repro',
  );
  expect(
    find.byKey(_startWithPresentKey),
    startWithPresent != null ? findsOneWidget : findsNothing,
    reason:
        'expected lobby-start-with-present-button '
        '${startWithPresent != null ? 'once' : 'nowhere'}. $repro',
  );
  if (startWithPresent != null) {
    final String label = loc.lobbyStartWithPresent(startWithPresent);
    expect(
      find.descendant(
        of: find.byKey(_startWithPresentKey),
        matching: find.text(label),
      ),
      findsOneWidget,
      reason: 'expected the start-with-present button to read "$label". $repro',
    );
  }
}

void main() {
  setUpAll(_loadAppFonts);

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  // --- D5: strings -------------------------------------------------------------

  group('D5 strings', () {
    Map<String, Object?> arb(String name) =>
        jsonDecode(File('lib/l10n/$name.arb').readAsStringSync())
            as Map<String, Object?>;

    test('lobbyWaitingForFriends is in both arb files with the contract '
        'texts and an @ description, and in both generated classes', () {
      final Map<String, Object?> en = arb('app_en');
      final Map<String, Object?> ar = arb('app_ar');
      expect(
        en['lobbyWaitingForFriends'],
        _friendsEn,
        reason: 'expected app_en.arb lobbyWaitingForFriends "$_friendsEn"',
      );
      expect(
        ar['lobbyWaitingForFriends'],
        _friendsAr,
        reason: 'expected app_ar.arb lobbyWaitingForFriends "$_friendsAr"',
      );
      final Object? meta = en['@lobbyWaitingForFriends'];
      expect(
        meta is Map<String, Object?> &&
            (meta['description'] as String?)?.trim().isNotEmpty == true,
        isTrue,
        reason: 'expected an @lobbyWaitingForFriends description in app_en.arb',
      );
      for (final String gen in <String>['en', 'ar']) {
        final String text = File('lib/l10n/gen/app_localizations_$gen.dart')
            .readAsStringSync();
        expect(
          text.contains('String get lobbyWaitingForFriends'),
          isTrue,
          reason:
              'expected the generated app_localizations_$gen.dart to carry '
              'lobbyWaitingForFriends (flutter gen-l10n was not re-run)',
        );
      }
    });

    test('a removed string is gone unless lib still reads it, and nothing '
        'in lib reads a string that is gone', () {
      final List<File> sources = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where(
            (File f) =>
                f.path.endsWith('.dart') && !f.path.contains('/l10n/gen/'),
          )
          .toList();
      final String all = sources
          .map((File f) => f.readAsStringSync())
          .join('\n');
      final Map<String, Object?> en = arb('app_en');
      final Map<String, Object?> ar = arb('app_ar');
      for (final String key in <String>[
        'homePlayersTwo',
        'homePlayersThree',
        'homePlayersFour',
        'homePlayersQuestion',
        'lobbyWaitingForPlayers',
      ]) {
        final bool read = RegExp('\\.$key\\b').hasMatch(all);
        expect(
          read,
          isFalse,
          reason:
              'D5: nothing in lib/ may read $key; the chip label is the '
              'name alone and the count control is gone',
        );
        final bool inEn = en.containsKey(key);
        final bool inAr = ar.containsKey(key);
        expect(
          inEn == inAr,
          isTrue,
          reason: 'expected $key in both arb files or in neither',
        );
        expect(
          inEn,
          read,
          reason:
              'D5: $key is ${inEn ? 'still in the arb files' : 'removed'} '
              'but lib/ ${read ? 'still reads' : 'no longer reads'} it; '
              'remove it only if nothing reads it, and read nothing that is '
              'removed',
        );
      }
    });

    test('player_count_icon.dart is deleted once lib no longer uses '
        'PlayerCountIcon', () {
      final List<File> others = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where(
            (File f) =>
                f.path.endsWith('.dart') &&
                !f.path.endsWith('player_count_icon.dart'),
          )
          .toList();
      final bool used = others.any(
        (File f) => f.readAsStringSync().contains('PlayerCountIcon'),
      );
      expect(
        File('lib/src/player_count_icon.dart').existsSync(),
        used,
        reason:
            'D5: lib/src/player_count_icon.dart must exist only while lib/ '
            'still uses PlayerCountIcon (${used ? 'it does' : 'it does not'})',
      );
    });
  });

  // Carried over from the players-row fit file C-666 retires: the fit cases
  // below are only evidence when the real fonts, not Ahem, are in effect.
  group('sanity: the real fonts loaded by setUpAll are in effect', () {
    test('Poppins: two 10-character Latin strings of very different letter '
        'shapes measure different natural widths', () {
      const double fontSize = 48;
      const String narrow = 'iiiiiiiiii';
      const String wide = 'WWWWWWWWWW';
      const TextStyle style = TextStyle(
        fontFamily: 'Poppins',
        fontSize: fontSize,
      );
      final double narrowWidth = _naturalWidthOf(
        narrow,
        style,
        TextDirection.ltr,
      );
      final double wideWidth = _naturalWidthOf(wide, style, TextDirection.ltr);
      expect(
        (narrowWidth - wideWidth).abs(),
        greaterThan(1.0),
        reason:
            'Poppins does not appear to have loaded: "$narrow" and "$wide" '
            'measured ${narrowWidth}dp and ${wideWidth}dp; equal widths are '
            'what the Ahem substitute would give',
      );
      expect(
        narrowWidth,
        isNot(closeTo(fontSize * narrow.length, 1.0)),
        reason:
            'Poppins does not appear to have loaded: "$narrow" measured '
            '${narrowWidth}dp, the Ahem width for ${narrow.length} '
            'characters at $fontSize',
      );
    });

    test('Noto Sans Arabic: two 5-character Arabic strings of very '
        'different letter shapes measure different natural widths', () {
      const double fontSize = 48;
      const String narrow = '\u0627\u0627\u0627\u0627\u0627';
      const String wide = '\u0645\u0645\u0645\u0645\u0645';
      const TextStyle style = TextStyle(
        fontFamily: 'Noto Sans Arabic',
        fontSize: fontSize,
      );
      final double narrowWidth = _naturalWidthOf(
        narrow,
        style,
        TextDirection.rtl,
      );
      final double wideWidth = _naturalWidthOf(wide, style, TextDirection.rtl);
      expect(
        (narrowWidth - wideWidth).abs(),
        greaterThan(1.0),
        reason:
            'Noto Sans Arabic does not appear to have loaded: the strings '
            'measured ${narrowWidth}dp and ${wideWidth}dp',
      );
      expect(
        narrowWidth,
        isNot(closeTo(fontSize * narrow.length, 1.0)),
        reason:
            'Noto Sans Arabic does not appear to have loaded: "$narrow" '
            'measured ${narrowWidth}dp, the Ahem width for 5 characters',
      );
    });

    testWidgets('the mounted home resolves its Create label to Poppins '
        'with Noto Sans Arabic in the fallback, off the real theme', (
      tester,
    ) async {
      await _mountHome(tester, locale: const Locale('en'));
      final String label = _loc(tester).homeCreateRoomButton;
      final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(of: find.byKey(_createKey), matching: find.text(label)),
      );
      final TextStyle? style = paragraph.text.style;
      expect(style, isNotNull, reason: 'fixture: the Create label has a style');
      expect(
        style!.fontFamily,
        'Poppins',
        reason:
            'expected the Create label to resolve fontFamily Poppins '
            '(lib/src/theme.dart kLudoFontFamily), got "${style.fontFamily}"',
      );
      expect(
        style.fontFamilyFallback,
        contains('Noto Sans Arabic'),
        reason:
            'expected fontFamilyFallback to contain Noto Sans Arabic, got '
            '${style.fontFamilyFallback}',
      );
    });
  });

  for (final Locale locale in _locales) {
    final String lc = locale.languageCode;

    // --- D1: home ---------------------------------------------------------------

    group('D1 home, $lc', () {
      testWidgets('no players control, no option, no question, no "players" '
          'word painted anywhere', (tester) async {
        const String name = 'home has no players control';
        final String repro = _repro(name, locale);
        await _mountHome(tester, locale: locale);

        expect(
          find.byKey(const Key('home-players-button'), skipOffstage: false),
          findsNothing,
          reason: 'expected no home-players-button on home. $repro',
        );
        for (final int n in <int>[2, 3, 4]) {
          expect(
            find.byKey(Key('home-players-option-$n'), skipOffstage: false),
            findsNothing,
            reason: 'expected no home-players-option-$n on home. $repro',
          );
        }
        await _scrollHomeToEnd(tester);
        final List<String> painted = _paintedStrings();
        expect(
          painted.where((String s) => s.contains(_question(locale))),
          isEmpty,
          reason:
              'expected the question "${_question(locale)}" painted nowhere; '
              'painted strings were $painted. $repro',
        );
        final List<String> hits = painted
            .where(
              (String s) => lc == 'ar'
                  ? (s.contains('لاعبين') || s.contains('لاعبان'))
                  : s.toLowerCase().contains('players'),
            )
            .toList();
        expect(
          hits,
          isEmpty,
          reason:
              'expected no painted text with the word for "players" on a '
              'home with no count to choose; found $hits. $repro',
        );
        expect(
          find.byWidgetPredicate(_isPlayerCountIcon, skipOffstage: false),
          findsNothing,
          reason: 'expected no PlayerCountIcon on a fresh home. $repro',
        );
      });

      testWidgets('the gap the control left is closed: less room between '
          'the name field and Create than a 48 dp row needs', (tester) async {
        const String name = 'no empty slot above create';
        final String repro = _repro(name, locale);
        await _mountHome(tester, locale: locale);

        final Rect field = tester.getRect(find.byKey(_nameKey));
        final Rect create = tester.getRect(find.byKey(_createKey));
        final double gap = create.top - field.bottom;
        expect(
          gap > 0,
          isTrue,
          reason:
              'expected Create below the name field; field $field, create '
              '$create. $repro',
        );
        expect(
          gap < 48,
          isTrue,
          reason:
              'expected the space between the name field and Create to be '
              'smaller than the 48 dp row the players control used to take '
              '(no empty slot); it is $gap dp (field $field, create '
              '$create). $repro',
        );
      });

      testWidgets('Create sends create_room with players 4 and the fixed '
          'rules, with nothing touched first', (tester) async {
        const String name = 'create sends four';
        final String repro = _repro(name, locale);
        final _LiveControllerFactory factory = _LiveControllerFactory();
        await _mountHome(
          tester,
          locale: locale,
          controllerFactory: factory.call,
        );
        final Map<String, Object?> data = await _tapCreateAndRead(
          tester,
          factory,
          repro,
        );
        expect(
          data['players'],
          4,
          reason:
              'expected create_room players 4; the frame carried '
              '${data['players']}. $repro',
        );
        expect(
          data['rules'],
          <String, Object?>{'capture_bonus': true},
          reason:
              'expected create_room rules exactly {capture_bonus: true}; '
              'the frame carried ${data['rules']}. $repro',
        );
        await _drainRequestTimeout(tester);
      });

      for (final int stored in <int>[2, 3, 4]) {
        testWidgets('a stored last table of $stored seats restores the name, '
            'shows no count icon, and Create still sends 4', (tester) async {
          final String name = 'stored table $stored seats';
          final String repro = _repro(name, locale);
          await SessionMemory.recordSuccessfulCreate(
            name: 'Zed Quartz',
            seats: stored,
          );
          final SemanticsHandle handle = tester.ensureSemantics();
          try {
            final _LiveControllerFactory factory = _LiveControllerFactory();
            await _mountHome(
              tester,
              locale: locale,
              controllerFactory: factory.call,
            );

            expect(
              tester.widget<TextField>(find.byKey(_nameKey)).controller!.text,
              'Zed Quartz',
              reason:
                  'expected the stored table name restored into the name '
                  'field. $repro',
            );
            final Finder chip = find.byKey(_lastTableKey);
            expect(
              chip,
              findsOneWidget,
              reason: 'expected the last-table chip to show. $repro',
            );
            final String painted = _paintedStrings(tester.element(chip))
                .join()
                .replaceAll(RegExp('[\\s·]'), '');
            expect(
              painted,
              'ZedQuartz',
              reason:
                  'expected the chip to paint the table name and nothing '
                  'else; it paints "$painted". $repro',
            );
            expect(
              find.descendant(
                of: chip,
                matching: find.byWidgetPredicate(_isPlayerCountIcon),
              ),
              findsNothing,
              reason: 'expected no PlayerCountIcon in the chip. $repro',
            );
            expect(
              find.descendant(
                of: chip,
                matching: find.byIcon(Icons.person_rounded),
              ),
              findsNothing,
              reason: 'expected no person figure in the chip. $repro',
            );
            final String spoken = tester.getSemantics(chip).label;
            expect(
              spoken.split('\n').first,
              'Zed Quartz',
              reason:
                  'expected the chip spoken label to be the table name '
                  'alone; got "$spoken". $repro',
            );
            expect(
              find.byKey(const Key('home-players-button'), skipOffstage: false),
              findsNothing,
              reason:
                  'expected a stored $stored-seat table not to bring the '
                  'players control back. $repro',
            );

            final Map<String, Object?> data = await _tapCreateAndRead(
              tester,
              factory,
              repro,
            );
            expect(
              data['players'],
              4,
              reason:
                  'expected Create to send players 4 whatever the stored '
                  'last table held ($stored); the frame carried '
                  '${data['players']}. $repro',
            );
            await _drainRequestTimeout(tester);
          } finally {
            handle.dispose();
          }
        });
      }

      testWidgets('a successful create stores a last table of 4 seats', (
        tester,
      ) async {
        const String name = 'create records four';
        final String repro = _repro(name, locale);
        final _LiveControllerFactory factory = _LiveControllerFactory();
        await _mountHome(
          tester,
          locale: locale,
          controllerFactory: factory.call,
        );
        await tester.enterText(find.byKey(_nameKey), 'Rima');
        await tester.pump();
        await tester.ensureVisible(find.byKey(_createKey));
        await tester.tap(find.byKey(_createKey));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        final FakeTransport transport = factory.transports.single;
        final String requestId = _idOf(transport.sentRaw.last);
        transport.pushText(
          _frame(
            type: 'seat_assigned',
            data: <String, Object?>{'seat': 0, 'seat_token': 'tok-0'},
          ),
        );
        transport.pushText(
          _frame(
            type: 'room',
            re: requestId,
            data: _roomJson(seats: _seats(1, names: <String>['Rima'])),
          ),
        );
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        final SessionMemory? loaded = await tester.runAsync(
          () => SessionMemory.load(),
        );
        expect(
          loaded?.lastSeats,
          4,
          reason:
              'expected the remembered table to record seats 4 after a '
              'create. $repro',
        );
        expect(
          loaded?.lastName,
          'Rima',
          reason: 'expected the remembered table name. $repro',
        );
      });
    });

    // --- D2: host lobby -----------------------------------------------------------

    group('D2 host lobby, $lc', () {
      testWidgets('1 seated: the waiting-for-friends line and no start '
          'control', (tester) async {
        const String name = 'host 1 of 4';
        await _mountLobby(tester, locale: locale, host: true, seated: 1);
        _expectLobbySet(
          tester,
          locale: locale,
          scenario: name,
          waitingFriends: true,
          waitingHost: false,
          startWithPresent: null,
          start: false,
        );
      });

      for (final int seated in <int>[2, 3]) {
        testWidgets('$seated seated of 4: one start-with-present button '
            'reading $seated, no waiting line, no full-room start', (
          tester,
        ) async {
          final String name = 'host $seated of 4';
          await _mountLobby(tester, locale: locale, host: true, seated: seated);
          _expectLobbySet(
            tester,
            locale: locale,
            scenario: name,
            waitingFriends: false,
            waitingHost: false,
            startWithPresent: seated,
            start: false,
          );
        });
      }

      testWidgets('4 seated: the full-room start button and nothing else', (
        tester,
      ) async {
        const String name = 'host 4 of 4';
        final String repro = _repro(name, locale);
        await _mountLobby(tester, locale: locale, host: true, seated: 4);
        _expectLobbySet(
          tester,
          locale: locale,
          scenario: name,
          waitingFriends: false,
          waitingHost: false,
          startWithPresent: null,
          start: true,
        );
        expect(
          find.descendant(
            of: find.byKey(_startKey),
            matching: find.text(_loc(tester).lobbyStartButton),
          ),
          findsOneWidget,
          reason: 'expected the full-room button to read "Start game". $repro',
        );
      });

      for (final bool host in <bool>[true, false]) {
        testWidgets('${host ? 'host' : 'guest'}: the grid shows 4 minus '
            'seated open-seat placeholders', (tester) async {
          for (final int seated in <int>[1, 2, 3, 4]) {
            final String name =
                '${host ? 'host' : 'guest'} placeholders $seated';
            if (!host && seated == 1) {
              continue;
            }
            await _mountLobby(
              tester,
              locale: locale,
              host: host,
              seated: seated,
            );
            expect(
              find.byType(OpenSeatCard, skipOffstage: false),
              findsNWidgets(4 - seated),
              reason:
                  'expected ${4 - seated} open-seat placeholders with '
                  '$seated of 4 seated. ${_repro(name, locale)}',
            );
            await tester.pumpWidget(const SizedBox());
          }
        });
      }

      testWidgets('the control set follows the room live: 1, 2, 4, 3, then '
          'back to 1', (tester) async {
        const String name = 'host control set follows the room';
        final _Lobby lobby = await _mountLobby(
          tester,
          locale: locale,
          host: true,
          seated: 1,
        );
        _expectLobbySet(
          tester,
          locale: locale,
          scenario: '$name / 1',
          waitingFriends: true,
          waitingHost: false,
          startWithPresent: null,
          start: false,
        );
        await _pushRoom(lobby, seated: 2, seq: 2);
        _expectLobbySet(
          tester,
          locale: locale,
          scenario: '$name / 2',
          waitingFriends: false,
          waitingHost: false,
          startWithPresent: 2,
          start: false,
        );
        await _pushRoom(lobby, seated: 4, seq: 3);
        _expectLobbySet(
          tester,
          locale: locale,
          scenario: '$name / 4',
          waitingFriends: false,
          waitingHost: false,
          startWithPresent: null,
          start: true,
        );
        await _pushRoom(lobby, seated: 3, seq: 4);
        _expectLobbySet(
          tester,
          locale: locale,
          scenario: '$name / 3',
          waitingFriends: false,
          waitingHost: false,
          startWithPresent: 3,
          start: false,
        );
        await _pushRoom(lobby, seated: 1, seq: 5);
        _expectLobbySet(
          tester,
          locale: locale,
          scenario: '$name / back to 1',
          waitingFriends: true,
          waitingHost: false,
          startWithPresent: null,
          start: false,
        );
      });

      group('a room an old client made with a fixed count', () {
        testWidgets('players 3: 1 seated waits, 2 seated starts with '
            'present, 3 seated is full', (tester) async {
          const String name = 'old client players 3';
          final _Lobby lobby = await _mountLobby(
            tester,
            locale: locale,
            host: true,
            seated: 1,
            players: 3,
          );
          _expectLobbySet(
            tester,
            locale: locale,
            scenario: '$name / 1 seated',
            waitingFriends: true,
            waitingHost: false,
            startWithPresent: null,
            start: false,
          );
          await _pushRoom(lobby, seated: 2, seq: 2, players: 3);
          _expectLobbySet(
            tester,
            locale: locale,
            scenario: '$name / 2 seated',
            waitingFriends: false,
            waitingHost: false,
            startWithPresent: 2,
            start: false,
          );
          await _pushRoom(lobby, seated: 3, seq: 3, players: 3);
          _expectLobbySet(
            tester,
            locale: locale,
            scenario: '$name / 3 seated',
            waitingFriends: false,
            waitingHost: false,
            startWithPresent: null,
            start: true,
          );
        });

        testWidgets('players 2: 2 seated is full and shows start, never '
            'start-with-present', (tester) async {
          const String name = 'old client players 2';
          await _mountLobby(
            tester,
            locale: locale,
            host: true,
            seated: 2,
            players: 2,
          );
          _expectLobbySet(
            tester,
            locale: locale,
            scenario: name,
            waitingFriends: false,
            waitingHost: false,
            startWithPresent: null,
            start: true,
          );
        });
      });
    });

    // --- D3: guest lobby ------------------------------------------------------------

    group('D3 guest lobby, $lc', () {
      for (final int seated in <int>[2, 3, 4]) {
        testWidgets('$seated seated of 4: always the waiting-for-host line, '
            'no seat count, no start control', (tester) async {
          final String name = 'guest $seated of 4';
          await _mountLobby(
            tester,
            locale: locale,
            host: false,
            seated: seated,
          );
          _expectLobbySet(
            tester,
            locale: locale,
            scenario: name,
            waitingFriends: false,
            waitingHost: true,
            startWithPresent: null,
            start: false,
          );
        });
      }

      testWidgets('an old-client room, players 3 with 2 seated, still says '
          'waiting for the host', (tester) async {
        const String name = 'guest old client 2 of 3';
        await _mountLobby(
          tester,
          locale: locale,
          host: false,
          seated: 2,
          players: 3,
        );
        _expectLobbySet(
          tester,
          locale: locale,
          scenario: name,
          waitingFriends: false,
          waitingHost: true,
          startWithPresent: null,
          start: false,
        );
      });

      testWidgets('the guest line does not change as the host room fills', (
        tester,
      ) async {
        const String name = 'guest line stable while filling';
        final _Lobby lobby = await _mountLobby(
          tester,
          locale: locale,
          host: false,
          seated: 2,
        );
        int seq = 1;
        for (final int seated in <int>[3, 4, 2]) {
          seq += 1;
          await _pushRoom(lobby, seated: seated, seq: seq);
          _expectLobbySet(
            tester,
            locale: locale,
            scenario: '$name / $seated',
            waitingFriends: false,
            waitingHost: true,
            startWithPresent: null,
            start: false,
          );
        }
      });
    });

    // --- the wire ----------------------------------------------------------------

    group('start with present, $lc', () {
      testWidgets('2 seated: the tap sends set_players 2, and only after its '
          'answer start_game, once each, in that order', (tester) async {
        const String name = 'start with 2 wire order';
        final String repro = _repro(name, locale);
        final _Lobby lobby = await _mountLobby(
          tester,
          locale: locale,
          host: true,
          seated: 2,
        );
        final FakeTransport transport = lobby.transport;
        final int before = transport.sentRaw.length;

        await tester.tap(find.byKey(_startWithPresentKey));
        await tester.pump();
        // A second tap while the first is in flight sends nothing.
        await tester.tap(find.byKey(_startWithPresentKey), warnIfMissed: false);
        await tester.pump();

        final List<String> afterTap = transport.sentRaw.skip(before).toList();
        expect(
          afterTap.map(_typeOf).toList(),
          <String>['set_players'],
          reason:
              'expected exactly one frame, set_players, after the tap and '
              'before any answer (no start_game yet, no second '
              'set_players); got ${afterTap.map(_typeOf).toList()}. $repro',
        );
        expect(
          _dataOf(afterTap.single),
          <String, Object?>{'players': 2},
          reason:
              'expected set_players {players: 2}; got '
              '${_dataOf(afterTap.single)}. $repro',
        );

        // The server answers with the canonical two-seat set, opposite
        // corners (PROTOCOL section 15), the room now full.
        transport.pushText(
          _frame(
            type: 'room',
            re: _idOf(afterTap.single),
            data: _roomJson(
              players: 2,
              seats: <Map<String, Object?>>[
                _seatJson(0, name: 'p0'),
                _seatJson(2, name: 'p1'),
              ],
              seq: 2,
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        final List<String> afterReply = transport.sentRaw
            .skip(before)
            .map(_typeOf)
            .toList();
        expect(
          afterReply,
          <String>['set_players', 'start_game'],
          reason:
              'expected set_players then start_game, in that order, one '
              'each; the host sent $afterReply. $repro',
        );

        transport.pushText(
          _frame(
            type: 'game_started',
            re: _idOf(transport.sentRaw.last),
            data: <String, Object?>{
              'turn': 0,
              'game_id': 'a' * 16,
              'client_seeds': '0:seed',
              'seq': 3,
            },
          ),
        );
        await tester.pump();
      });

      testWidgets('3 seated: the tap sends set_players 3', (tester) async {
        const String name = 'start with 3 wire';
        final String repro = _repro(name, locale);
        final _Lobby lobby = await _mountLobby(
          tester,
          locale: locale,
          host: true,
          seated: 3,
        );
        final FakeTransport transport = lobby.transport;
        final int before = transport.sentRaw.length;
        await tester.tap(find.byKey(_startWithPresentKey));
        await tester.pump();
        final List<String> afterTap = transport.sentRaw.skip(before).toList();
        expect(afterTap.map(_typeOf).toList(), <String>[
          'set_players',
        ], reason: 'expected one set_players after the tap. $repro');
        expect(_dataOf(afterTap.single), <String, Object?>{
          'players': 3,
        }, reason: 'expected set_players {players: 3}. $repro');
        transport.pushText(
          _frame(
            type: 'room',
            re: _idOf(afterTap.single),
            data: _roomJson(players: 3, seats: _seats(3), seq: 2),
          ),
        );
        await tester.pump();
        await tester.pump();
        transport.pushText(
          _frame(
            type: 'game_started',
            re: _idOf(transport.sentRaw.last),
            data: <String, Object?>{
              'turn': 0,
              'game_id': 'a' * 16,
              'client_seeds': '0:seed',
              'seq': 3,
            },
          ),
        );
        await tester.pump();
      });

      testWidgets('4 seated: the full-room button sends start_game with no '
          'set_players', (tester) async {
        const String name = 'start full wire';
        final String repro = _repro(name, locale);
        final _Lobby lobby = await _mountLobby(
          tester,
          locale: locale,
          host: true,
          seated: 4,
        );
        final int before = lobby.transport.sentRaw.length;
        await tester.tap(find.byKey(_startKey));
        await tester.pump();
        final List<String> afterTap = lobby.transport.sentRaw
            .skip(before)
            .map(_typeOf)
            .toList();
        expect(
          afterTap,
          <String>['start_game'],
          reason:
              'expected the full room to send start_game alone; got '
              '$afterTap. $repro',
        );
        await tester.pump(const Duration(seconds: 11));
      });
    });

    // --- fit --------------------------------------------------------------------------

    const Size small = Size(320, 568);

    testWidgets('320x568 at text scale 2.0, $lc: home throws no layout '
        'exception and Create is reachable', (tester) async {
      const String name = 'home small and large';
      final String repro = _repro(name, locale, '320x568 at 2.0');
      await _mountHome(tester, locale: locale, size: small, textScale: 2.0);
      expect(
        tester.takeException(),
        isNull,
        reason: 'expected no layout exception on home. $repro',
      );
      await tester.ensureVisible(find.byKey(_createKey));
      await tester.pump();
      expect(
        tester.takeException(),
        isNull,
        reason: 'expected no exception scrolling to Create. $repro',
      );
      final Rect create = tester.getRect(find.byKey(_createKey));
      expect(
        create.left >= 0 && create.right <= small.width,
        isTrue,
        reason: 'expected Create inside the 320 dp width; got $create. $repro',
      );
    });

    testWidgets('320x568 at text scale 2.0, $lc: home with a long stored '
        'last table name throws no layout exception', (tester) async {
      const String name = 'home small and large with chip';
      final String repro = _repro(name, locale, '320x568 at 2.0');
      await SessionMemory.recordSuccessfulCreate(
        name: lc == 'ar'
            ? 'عبد الرحمن المنصوري الكبير'
            : 'Abdelrahman Al-Mansouri',
        seats: 4,
      );
      await _mountHome(tester, locale: locale, size: small, textScale: 2.0);
      expect(
        find.byKey(_lastTableKey),
        findsOneWidget,
        reason: 'fixture: the stored table must show its chip. $repro',
      );
      expect(
        tester.takeException(),
        isNull,
        reason: 'expected no layout exception on home with the chip. $repro',
      );
    });

    testWidgets('320x568 at text scale 2.0, $lc: the host lobby with 2 '
        'seated throws no layout exception and the button is on screen', (
      tester,
    ) async {
      const String name = 'lobby small and large 2 seated';
      final String repro = _repro(name, locale, '320x568 at 2.0');
      await _mountLobby(
        tester,
        locale: locale,
        host: true,
        seated: 2,
        names: lc == 'ar'
            ? <String>['عبد الرحمن المنصوري', 'فاطمة الزهراء']
            : <String>['Abdelrahman Al-Mansouri', 'Fatima Al-Zahra'],
        size: small,
        textScale: 2.0,
      );
      expect(
        tester.takeException(),
        isNull,
        reason: 'expected no layout exception in the 2-seated lobby. $repro',
      );
      final Finder button = find.byKey(_startWithPresentKey);
      expect(
        button,
        findsOneWidget,
        reason: 'expected the start-with-present button. $repro',
      );
      final Rect rect = tester.getRect(button);
      expect(
        rect.left >= 0 &&
            rect.right <= small.width &&
            rect.top >= 0 &&
            rect.bottom <= small.height,
        isTrue,
        reason:
            'expected the docked start button wholly on the 320x568 screen '
            'at text scale 2.0; it is at $rect. $repro',
      );
    });

    testWidgets('320x568 at text scale 2.0, $lc: the host lobby with 1 '
        'seated throws no layout exception', (tester) async {
      const String name = 'lobby small and large 1 seated';
      final String repro = _repro(name, locale, '320x568 at 2.0');
      await _mountLobby(
        tester,
        locale: locale,
        host: true,
        seated: 1,
        size: small,
        textScale: 2.0,
      );
      expect(
        tester.takeException(),
        isNull,
        reason: 'expected no layout exception in the 1-seated lobby. $repro',
      );
      expect(
        find.text(_friends(locale)),
        findsOneWidget,
        reason: 'expected the waiting-for-friends line. $repro',
      );
    });
  }
}
