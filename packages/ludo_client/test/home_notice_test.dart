// Proof for contract C-449 (work/ludo/orders/C-449-home-notice-reads-as-news.md):
// the line that says why the player is back on Home reads as news, not as a
// grey caption under a form.
//
// Written from the contract and from the rigs in
// test/relaunch_back_to_game_test.dart (a refused resume reaching Home) and
// test/leave_table_end_card_test.dart (the removed notice). Nothing here was
// derived from the body of home_screen.dart.
//
// Case ids follow the contract's decisions:
//   N1, N2   D1  one card, key home-notice, around the removed / game-gone
//                text; one info icon; the text is not inkMuted
//   N3       D1  the card sits under the title block and above the name row
//   N4       D1  one notice at a time; the newer one replaces the older one
//   N5       D2  a dismiss control at least 48 x 48 that removes the card
//   N5b      D2  the dismiss control carries a semantics label
//   N5c      D2  the card also goes away on the events that hide it today
//   N6       D3  the card mirrors in ar (icon right, dismiss left)
//   N7       D3  360 x 640 at text scale 2.0: no overflow, text wraps inside
//   N8       D4  with no notice there is no card and Create Room has not moved
//   N8b      D4  after a notice is dismissed Create Room is back where it was
//
// How each notice is reached, with real clients on the real wire format over
// a FakeTransport and no mocked Home:
//   removed    Create Room, a LOBBY room reply, then a player_left frame that
//              names this seat (leave_table_end_card_test rule 3).
//   game-gone  a legacy seat record (session.seat alone, so the button shows
//              and nothing resumes on its own), a tap on home-rejoin-button,
//              and an error NO_SUCH_ROOM answering the resume
//              (relaunch_back_to_game_test R8c).
//
// Hygiene: one pumpWidget per case; every pump after a route can be pushed is
// bounded; every request a case leaves unanswered is flushed past
// RoomConnection's ten second timeout, and the tree is unmounted and the
// controllers disposed in a finally block inside the body, so no timer is
// pending when a case ends, whether it passed or not.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/die_mark.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

const Key _noticeKey = Key('home-notice');
const Key _dismissKey = Key('home-notice-dismiss');
const Key _removedTextKey = Key('home-removed-notice');
const Key _goneTextKey = Key('home-game-gone-notice');
const Key _nameKey = Key('home-name-field');
const Key _createKey = Key('create-room-button');
const Key _rejoinKey = Key('home-rejoin-button');

const String _testUrl = 'wss://home-notice-test.invalid/ws';

const String _seatPrefsKey = 'session.seat';
const String _kCode = 'K7M2QP';
const int _kSeat = 2;
const String _kToken = 'tok-home-notice-001';

// Create Room's top edge on the base commit (integrate/run107-relaunch at
// 9daed5b), no notice, no stored seat, locale en, the default 800 x 600 test
// surface. Measured by running the N8 case on that commit: the first run
// printed "create-room-button top is 330.0".
const double _kCreateTopOnBase = 330.0;

enum _Notice { removed, gone }

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'home-notice-srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;
String _idOf(String sentText) => _decode(sentText)['id']! as String;
String _typeOf(String sentText) => _decode(sentText)['t']! as String;

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
      'tokens': const <int>[-1, -1, -1, -1],
      'client_seed': null,
      'seed_origin': null,
    };

Map<String, Object?> _lobbyRoomJson() => <String, Object?>{
  'code': 'HN4NTC',
  'state': 'LOBBY',
  'host_seat': 0,
  'players': 3,
  'rules': const <String, Object?>{
    'blocks': true,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': null,
  'client_seeds': null,
  'seats': <Map<String, Object?>>[
    _seatJson(0, name: 'Sam'),
    _seatJson(1, name: 'Bob'),
  ],
  'turn': null,
  'winner': null,
  'seq': 1,
};

/// A controller that remembers whether [dispose] has run: Home retires the
/// controllers it owns when a route pops, and a ChangeNotifier refuses a
/// second dispose.
class _TrackedController extends RoomController {
  _TrackedController({required super.serverUrl, required super.connect});

  bool wasDisposed = false;

  @override
  void dispose() {
    wasDisposed = true;
    super.dispose();
  }
}

class _Factory {
  final List<_TrackedController> controllers = <_TrackedController>[];
  final List<FakeTransport> transports = <FakeTransport>[];

  RoomController call() {
    final FakeTransport transport = FakeTransport();
    transports.add(transport);
    final _TrackedController created = _TrackedController(
      serverUrl: Uri.parse(_testUrl),
      connect: (Uri url) async => transport,
    );
    controllers.add(created);
    return created;
  }

  List<String> sent(FakeTransport transport, String type) => <String>[
    for (final String s in transport.sentRaw)
      if (_typeOf(s) == type) s,
  ];

  void disposeAll() {
    for (final _TrackedController c in controllers) {
      if (!c.wasDisposed) {
        c.dispose();
      }
    }
  }
}

/// Seeds the mock store: a legacy seat record (session.seat alone) when
/// [withSeat], nothing otherwise.
void _seed({required bool withSeat}) {
  SharedPreferences.setMockInitialValues(<String, Object>{
    if (withSeat) _seatPrefsKey: <String>[_kCode, _kSeat.toString(), _kToken],
  });
}

Widget _app(
  _Factory factory, {
  Locale locale = const Locale('en'),
  double textScale = 1.0,
}) {
  return MaterialApp(
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    builder: (BuildContext context, Widget? child) {
      return MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      );
    },
    home: HomeScreen(onToggleLocale: () {}, controllerFactory: factory.call),
  );
}

/// Bounded pumps only, never pumpAndSettle: long enough for the session
/// memory load, the intro animation and a route transition.
Future<void> _pumpBounded(WidgetTester tester, {int frames = 8}) async {
  for (int i = 0; i < frames; i += 1) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _mount(WidgetTester tester, Widget app) async {
  await tester.pumpWidget(app);
  await _pumpBounded(tester);
}

AppLocalizations _loc(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(Scaffold).first));

/// Flushes any request still waiting on RoomConnection's ten second timeout,
/// unmounts the tree so no listener outlives its controller, disposes the
/// controllers, and puts the test surface back.
Future<void> _finish(WidgetTester tester, _Factory factory) async {
  await tester.pump(const Duration(seconds: 11));
  await tester.pump();
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  factory.disposeAll();
  await tester.pump();
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
}

/// Runs [body] and always finishes the case, so a failed expectation leaves
/// no timer or listener behind to drown the real failure.
Future<void> _guarded(
  WidgetTester tester,
  _Factory factory,
  Future<void> Function() body,
) async {
  try {
    await body();
  } finally {
    await _finish(tester, factory);
  }
}

void _useSurface(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
}

/// Reaches home-removed-notice: Create Room, a LOBBY room reply, and a
/// player_left that names this seat, which pops the lobby back to Home.
Future<void> _driveRemoved(
  WidgetTester tester,
  _Factory factory, {
  required String scenario,
}) async {
  await tester.ensureVisible(find.byKey(_createKey));
  await tester.tap(find.byKey(_createKey));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  expect(
    factory.transports,
    isNotEmpty,
    reason: '$scenario: fixture broken, Create Room built no controller',
  );
  final FakeTransport transport = factory.transports.last;
  final List<String> creates = factory.sent(transport, 'create_room');
  expect(
    creates,
    hasLength(1),
    reason: '$scenario: fixture broken, no create_room frame was sent',
  );
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': 1, 'seat_token': 'tok-1'},
    ),
  );
  transport.pushText(
    _frame(type: 'room', re: _idOf(creates.single), data: _lobbyRoomJson()),
  );
  await tester.pump();
  await tester.pump();
  transport.pushText(
    _frame(type: 'player_left', data: <String, Object?>{'seat': 1, 'seq': 2}),
  );
  await tester.pump();
  await tester.pump();
  await _pumpBounded(tester, frames: 6);
}

/// Reaches home-game-gone-notice: a tap on the button the legacy seat record
/// shows, answered NO_SUCH_ROOM.
Future<void> _driveRefusedResume(
  WidgetTester tester,
  _Factory factory, {
  required String scenario,
}) async {
  expect(
    find.byKey(_rejoinKey),
    findsOneWidget,
    reason:
        '$scenario: fixture broken, a legacy seat record must show '
        'home-rejoin-button',
  );
  await tester.ensureVisible(find.byKey(_rejoinKey));
  await tester.tap(find.byKey(_rejoinKey));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  expect(
    factory.transports,
    isNotEmpty,
    reason: '$scenario: fixture broken, the tap built no controller',
  );
  final FakeTransport transport = factory.transports.last;
  final List<String> resumes = factory.sent(transport, 'resume');
  expect(
    resumes,
    hasLength(1),
    reason: '$scenario: fixture broken, no resume frame was sent',
  );
  transport.pushText(
    _frame(
      type: 'error',
      re: _idOf(resumes.single),
      data: <String, Object?>{'code': 'NO_SUCH_ROOM', 'message': ''},
    ),
  );
  await tester.pump();
  await tester.pump();
  await _pumpBounded(tester, frames: 6);
}

Future<void> _driveNotice(
  WidgetTester tester,
  _Factory factory,
  _Notice notice, {
  required String scenario,
}) {
  switch (notice) {
    case _Notice.removed:
      return _driveRemoved(tester, factory, scenario: scenario);
    case _Notice.gone:
      return _driveRefusedResume(tester, factory, scenario: scenario);
  }
}

Key _textKeyOf(_Notice notice) =>
    notice == _Notice.removed ? _removedTextKey : _goneTextKey;

String _textOf(AppLocalizations loc, _Notice notice) =>
    notice == _Notice.removed ? loc.homeRemovedNotice : loc.homeGameGoneNotice;

/// The notice's resolved text colour, read from the rendered RichText.
Color? _renderedColor(WidgetTester tester, Key textKey) {
  final Finder rich = find.descendant(
    of: find.byKey(textKey),
    matching: find.byType(RichText),
  );
  expect(
    rich,
    findsOneWidget,
    reason: 'the notice text under $textKey must render one RichText',
  );
  return tester.widget<RichText>(rich).text.style?.color;
}

/// What a screen reader announces for the dismiss control: the semantics
/// label plus the tooltip, because a tooltip is how the stock icon button
/// carries its name and it lands in the node's tooltip field, not its label.
String _spokenName(WidgetTester tester) {
  final SemanticsData data = tester
      .getSemantics(find.byKey(_dismissKey))
      .getSemanticsData();
  return '${data.label} ${data.tooltip}'.trim();
}

Finder _inCard(Finder matching) =>
    find.descendant(of: find.byKey(_noticeKey), matching: matching);

/// The lowest bottom edge of the title block: the app title, the tagline and
/// the die mark when the layout has one under them.
double _titleBlockBottom(WidgetTester tester) {
  final AppLocalizations loc = _loc(tester);
  double bottom = double.negativeInfinity;
  for (final Finder f in <Finder>[
    find.text(loc.appTitle),
    find.text(loc.homeTagline),
    find.byType(DieMark),
  ]) {
    for (int i = 0; i < f.evaluate().length; i += 1) {
      final double b = tester.getRect(f.at(i)).bottom;
      if (b > bottom) {
        bottom = b;
      }
    }
  }
  return bottom;
}

void main() {
  // ----------------------------------------------------------------- D1
  for (final _Notice notice in _Notice.values) {
    final String id = notice == _Notice.removed ? 'N1' : 'N2';
    final String key = notice == _Notice.removed
        ? 'home-removed-notice'
        : 'home-game-gone-notice';
    testWidgets('$id (D1): after ${notice.name} the text $key sits in one card '
        'home-notice with one info icon, and is not inkMuted', (tester) async {
      _seed(withSeat: notice == _Notice.gone);
      final _Factory factory = _Factory();
      final String scenario = '$id ${notice.name}, locale en, 800x600';
      await _mount(tester, _app(factory));
      await _guarded(tester, factory, () async {
        await _driveNotice(tester, factory, notice, scenario: scenario);

        expect(
          find.byKey(_noticeKey),
          findsOneWidget,
          reason:
              '$scenario: expected one widget keyed home-notice around the '
              'notice; found ${find.byKey(_noticeKey).evaluate().length}',
        );
        expect(
          _inCard(find.byKey(_textKeyOf(notice))),
          findsOneWidget,
          reason:
              '$scenario: $key must be a descendant of home-notice (the card '
              'is its ancestor)',
        );
        expect(
          _inCard(find.byIcon(Icons.info_outline_rounded)),
          findsOneWidget,
          reason:
              '$scenario: the card must hold exactly one '
              'Icons.info_outline_rounded; found '
              '${_inCard(find.byIcon(Icons.info_outline_rounded)).evaluate().length}',
        );
        final Text text = tester.widget<Text>(find.byKey(_textKeyOf(notice)));
        expect(
          text.data,
          _textOf(_loc(tester), notice),
          reason: '$scenario: the notice string must be unchanged',
        );
        final Color? color = _renderedColor(tester, _textKeyOf(notice));
        expect(
          color,
          isNotNull,
          reason: '$scenario: the notice text must resolve to a colour',
        );
        expect(
          color,
          isNot(LudoColors.inkMuted),
          reason:
              '$scenario: the notice text is rendered in $color, which is '
              'LudoColors.inkMuted; it must read as news, not as a caption',
        );
      });
    });
  }

  // ------------------------------------------------------- D1 position
  for (final _Notice notice in _Notice.values) {
    testWidgets(
      'N3 (D1): the card for ${notice.name} is under the title block and '
      'above the name row',
      (tester) async {
        _seed(withSeat: notice == _Notice.gone);
        final _Factory factory = _Factory();
        final String scenario = 'N3 ${notice.name}, locale en, 800x600';
        await _mount(tester, _app(factory));
        await _guarded(tester, factory, () async {
          await _driveNotice(tester, factory, notice, scenario: scenario);

          expect(
            find.byKey(_noticeKey),
            findsOneWidget,
            reason: '$scenario: home-notice is absent, so it has no position',
          );
          final double noticeTop = tester.getRect(find.byKey(_noticeKey)).top;
          final double nameTop = tester.getRect(find.byKey(_nameKey)).top;
          final double titleBottom = _titleBlockBottom(tester);
          expect(
            noticeTop,
            lessThan(nameTop),
            reason:
                '$scenario: the card top ($noticeTop) must be above the name '
                'row top ($nameTop)',
          );
          expect(
            noticeTop,
            greaterThanOrEqualTo(titleBottom),
            reason:
                '$scenario: the card top ($noticeTop) must not overlap the '
                'title block, which ends at $titleBottom',
          );
        });
      },
    );
  }

  // ------------------------------------------------- D1 one at a time
  testWidgets('N4 (D1): removed, then a refused resume: only the game-gone '
      'notice is up', (tester) async {
    _seed(withSeat: true);
    final _Factory factory = _Factory();
    const String scenario = 'N4 removed then refused resume, locale en';
    await _mount(tester, _app(factory));
    await _guarded(tester, factory, () async {
      await _driveRemoved(tester, factory, scenario: scenario);
      expect(
        find.byKey(_removedTextKey),
        findsOneWidget,
        reason: '$scenario: fixture broken, the removed notice never showed',
      );
      expect(
        find.byKey(_rejoinKey),
        findsOneWidget,
        reason:
            '$scenario: fixture broken, the stored seat button is needed for '
            'the second step and is gone after the removed pop',
      );
      await _driveRefusedResume(tester, factory, scenario: scenario);

      expect(
        find.byKey(_goneTextKey),
        findsOneWidget,
        reason: '$scenario: home-game-gone-notice must be up',
      );
      expect(
        find.byKey(_removedTextKey),
        findsNothing,
        reason: '$scenario: home-removed-notice must be gone, not stacked',
      );
      expect(
        find.byKey(_noticeKey),
        findsOneWidget,
        reason:
            '$scenario: exactly one home-notice card; found '
            '${find.byKey(_noticeKey).evaluate().length}',
      );
      expect(
        _inCard(find.byKey(_goneTextKey)),
        findsOneWidget,
        reason: '$scenario: the one card must hold the game-gone text',
      );
    });
  });

  // ----------------------------------------------------------------- D2
  for (final _Notice notice in _Notice.values) {
    testWidgets(
      'N5 (D2): the card for ${notice.name} has a dismiss control of at '
      'least 48 x 48 that removes it and leaves Create Room',
      (tester) async {
        _seed(withSeat: notice == _Notice.gone);
        final _Factory factory = _Factory();
        final String scenario = 'N5 ${notice.name}, locale en, 800x600';
        await _mount(tester, _app(factory));
        await _guarded(tester, factory, () async {
          await _driveNotice(tester, factory, notice, scenario: scenario);

          expect(
            _inCard(find.byKey(_dismissKey)),
            findsOneWidget,
            reason:
                '$scenario: home-notice-dismiss must be found inside '
                'home-notice',
          );
          final Size size = tester.getSize(find.byKey(_dismissKey));
          expect(
            size.width >= 48 && size.height >= 48,
            isTrue,
            reason:
                '$scenario: the dismiss control is $size; its hit area must '
                'be at least 48 x 48',
          );

          await tester.tap(find.byKey(_dismissKey));
          await tester.pump();
          await _pumpBounded(tester, frames: 4);

          expect(
            find.byKey(_noticeKey),
            findsNothing,
            reason:
                '$scenario: a tap on the dismiss control must remove the card',
          );
          expect(
            find.byKey(_textKeyOf(notice)),
            findsNothing,
            reason: '$scenario: the notice text must go with the card',
          );
          expect(
            find.byKey(_createKey),
            findsOneWidget,
            reason: '$scenario: Create Room must still be on Home',
          );
        });
      },
    );
  }

  testWidgets('N5b (D2): the dismiss control carries a semantics label '
      '(Dismiss in en)', (tester) async {
    _seed(withSeat: true);
    final _Factory factory = _Factory();
    const String scenario = 'N5b game-gone, locale en';
    final SemanticsHandle handle = tester.ensureSemantics();
    try {
      await _mount(tester, _app(factory));
      await _guarded(tester, factory, () async {
        await _driveRefusedResume(tester, factory, scenario: scenario);
        expect(
          find.byKey(_dismissKey),
          findsOneWidget,
          reason: '$scenario: no home-notice-dismiss to label',
        );
        final String label = _spokenName(tester);
        expect(
          label,
          contains('Dismiss'),
          reason:
              '$scenario: the dismiss control label is "$label"; the '
              'contract names a new string homeNoticeDismiss, en "Dismiss"',
        );
      });
    } finally {
      handle.dispose();
    }
  });

  testWidgets('N5b (D2): the dismiss control carries a semantics label '
      '(the Arabic string in ar)', (tester) async {
    _seed(withSeat: true);
    final _Factory factory = _Factory();
    const String scenario = 'N5b game-gone, locale ar';
    final SemanticsHandle handle = tester.ensureSemantics();
    try {
      await _mount(tester, _app(factory, locale: const Locale('ar')));
      await _guarded(tester, factory, () async {
        await _driveRefusedResume(tester, factory, scenario: scenario);
        expect(
          find.byKey(_dismissKey),
          findsOneWidget,
          reason: '$scenario: no home-notice-dismiss to label',
        );
        final String label = _spokenName(tester);
        expect(
          label,
          contains('إغلاق'),
          reason:
              '$scenario: the dismiss control label is "$label"; the '
              'contract names homeNoticeDismiss, ar "إغلاق"',
        );
      });
    } finally {
      handle.dispose();
    }
  });

  testWidgets('N5c (D2): tapping Create Room takes the removed card away '
      'with it, leaving no empty card', (tester) async {
    _seed(withSeat: false);
    final _Factory factory = _Factory();
    const String scenario = 'N5c removed then Create Room, locale en';
    await _mount(tester, _app(factory));
    await _guarded(tester, factory, () async {
      await _driveRemoved(tester, factory, scenario: scenario);
      expect(
        find.byKey(_noticeKey),
        findsOneWidget,
        reason: '$scenario: home-notice is absent, so there is no card to hide',
      );

      await tester.ensureVisible(find.byKey(_createKey));
      await tester.tap(find.byKey(_createKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.byKey(_noticeKey, skipOffstage: false),
        findsNothing,
        reason:
            '$scenario: Create Room hides the removed notice today; the '
            'whole card must go, not only its text',
      );
    });
  });

  testWidgets('N5c (D2): tapping Create Room takes the game-gone card away '
      'with it, leaving no empty card', (tester) async {
    // A refused resume clears the stored seat, so the rejoin button is gone
    // and Create Room is the event left that hides this notice today.
    _seed(withSeat: true);
    final _Factory factory = _Factory();
    const String scenario = 'N5c game-gone then Create Room, locale en';
    await _mount(tester, _app(factory));
    await _guarded(tester, factory, () async {
      await _driveRefusedResume(tester, factory, scenario: scenario);
      expect(
        find.byKey(_noticeKey),
        findsOneWidget,
        reason: '$scenario: home-notice is absent, so there is no card to hide',
      );

      await tester.ensureVisible(find.byKey(_createKey));
      await tester.tap(find.byKey(_createKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.byKey(_noticeKey, skipOffstage: false),
        findsNothing,
        reason:
            '$scenario: Create Room hides the game-gone notice today; the '
            'whole card must go',
      );
    });
  });

  // ----------------------------------------------------------------- D3
  for (final Locale locale in <Locale>[
    const Locale('en'),
    const Locale('ar'),
  ]) {
    for (final _Notice notice in _Notice.values) {
      testWidgets(
        'N6 (D3): the ${notice.name} card mirrors in ${locale.languageCode}',
        (tester) async {
          _seed(withSeat: notice == _Notice.gone);
          final _Factory factory = _Factory();
          final String scenario =
              'N6 ${notice.name}, locale ${locale.languageCode}, 800x600';
          await _mount(tester, _app(factory, locale: locale));
          await _guarded(tester, factory, () async {
            await _driveNotice(tester, factory, notice, scenario: scenario);

            expect(
              find.byKey(_noticeKey),
              findsOneWidget,
              reason: '$scenario: home-notice is absent, nothing to mirror',
            );
            expect(
              find.byKey(_dismissKey),
              findsOneWidget,
              reason: '$scenario: home-notice-dismiss is absent',
            );
            final double iconX = tester
                .getCenter(_inCard(find.byIcon(Icons.info_outline_rounded)))
                .dx;
            final double textX = tester
                .getCenter(find.byKey(_textKeyOf(notice)))
                .dx;
            final double dismissX = tester
                .getCenter(find.byKey(_dismissKey))
                .dx;
            final String where =
                'icon centre x=$iconX, text centre x=$textX, dismiss centre '
                'x=$dismissX';
            if (locale.languageCode == 'ar') {
              expect(
                iconX > textX && dismissX < textX,
                isTrue,
                reason:
                    '$scenario: in ar the icon must be right of the text and '
                    'the dismiss control left of it; $where',
              );
            } else {
              expect(
                iconX < textX && dismissX > textX,
                isTrue,
                reason:
                    '$scenario: in en the icon must be left of the text and '
                    'the dismiss control right of it; $where',
              );
            }
          });
        },
      );
    }
  }

  for (final Locale locale in <Locale>[
    const Locale('en'),
    const Locale('ar'),
  ]) {
    testWidgets('N7 (D3): 360 x 640 at text scale 2.0 in '
        '${locale.languageCode}: the game-gone card wraps inside itself with '
        'no overflow', (tester) async {
      _seed(withSeat: true);
      _useSurface(tester, const Size(360, 640));
      final _Factory factory = _Factory();
      final String scenario =
          'N7 game-gone, locale ${locale.languageCode}, 360x640, scale 2.0';
      await _mount(tester, _app(factory, locale: locale, textScale: 2.0));
      await _guarded(tester, factory, () async {
        await _driveRefusedResume(tester, factory, scenario: scenario);

        final Object? error = tester.takeException();
        expect(
          error,
          isNull,
          reason: '$scenario: the layout threw (overflow?): $error',
        );
        expect(
          find.byKey(_noticeKey),
          findsOneWidget,
          reason: '$scenario: home-notice is absent',
        );
        final Rect card = tester.getRect(find.byKey(_noticeKey));
        final Rect text = tester.getRect(find.byKey(_goneTextKey));
        expect(
          card.left >= 0 && card.right <= 360,
          isTrue,
          reason: '$scenario: the card $card leaves the 360 dp screen',
        );
        expect(
          text.left >= card.left && text.right <= card.right,
          isTrue,
          reason:
              '$scenario: the text $text must wrap inside the card $card, '
              'not run past it',
        );
        expect(
          text.top >= card.top && text.bottom <= card.bottom,
          isTrue,
          reason: '$scenario: the text $text must sit inside the card $card',
        );
      });
    });
  }

  // ----------------------------------------------------------------- D4
  testWidgets('N8 (D4): with no notice there is no card, and Create Room is '
      'where it was on the base commit', (tester) async {
    _seed(withSeat: false);
    final _Factory factory = _Factory();
    const String scenario = 'N8 no notice, no seat, locale en, 800x600';
    await _mount(tester, _app(factory));
    await _guarded(tester, factory, () async {
      expect(
        find.byKey(_noticeKey, skipOffstage: false),
        findsNothing,
        reason: '$scenario: home-notice must be absent when nothing is shown',
      );
      final double top = tester.getRect(find.byKey(_createKey)).top;
      expect(
        top,
        _kCreateTopOnBase,
        reason:
            '$scenario: create-room-button top is $top; on the base commit '
            '(9daed5b) it is $_kCreateTopOnBase',
      );
    });
  });

  testWidgets('N8b (D4): after a refused resume is dismissed, Create Room is '
      'back where it is with no notice and no stored seat', (tester) async {
    _seed(withSeat: true);
    final _Factory factory = _Factory();
    const String scenario = 'N8b game-gone then dismiss, locale en, 800x600';
    await _mount(tester, _app(factory));
    await _guarded(tester, factory, () async {
      await _driveRefusedResume(tester, factory, scenario: scenario);
      expect(
        find.byKey(_dismissKey),
        findsOneWidget,
        reason: '$scenario: no home-notice-dismiss to tap',
      );
      await tester.tap(find.byKey(_dismissKey));
      await tester.pump();
      await _pumpBounded(tester, frames: 4);

      expect(
        find.byKey(_noticeKey, skipOffstage: false),
        findsNothing,
        reason: '$scenario: the card must be gone after the dismiss tap',
      );
      expect(
        find.byKey(_rejoinKey, skipOffstage: false),
        findsNothing,
        reason: '$scenario: the refused resume cleared the seat record',
      );
      final double top = tester.getRect(find.byKey(_createKey)).top;
      expect(
        top,
        _kCreateTopOnBase,
        reason:
            '$scenario: create-room-button top is $top; with no notice and '
            'no seat it is $_kCreateTopOnBase (the N8 value). A gap left by '
            'the dismissed card moves it',
      );
    });
  });
}
