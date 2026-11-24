// Proof for order 701 (the two-button home, the create and join sheets, name
// required), written from the order and docs/PROTOCOL.md sections 33 and 34
// item 2, not from the home's code.
//
// Every row runs in English and Arabic at 320x640 and at 412x915 over a real
// HomeScreen on the project's fake transport. A failure names the variant,
// the row and the command that reruns it. Social paths count their taps
// (doctrine P5) and the count is asserted, so a tap added to a path fails.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/account.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/session_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/c701_harness.dart';
import 'support/home_flow.dart';

const String _file = 'c701_two_button_home_test.dart';
const String _linkId = 't5k2q9a-x7m3pd';
final Uri _link = Uri.parse('https://ludo.provefair.app/r/$_linkId');
const String _savedName = 'Nour';
const Map<String, Object> _savedNamePrefs = <String, Object>{
  'session.lastName': _savedName,
  'session.lastSeats': 4,
};
const String _goodCode = 'K7M2QP';
const String _badCode = 'AB#234';

void row(
  String name,
  Future<void> Function(C701Rig rig) body, {
  List<C701Variant> variants = kVariants,
}) {
  for (final C701Variant v in variants) {
    final String full = '${v.id}: $name';
    testWidgets(full, (WidgetTester tester) async {
      final C701Rig rig = C701Rig(tester, v, file: _file, row: full);
      await runRow(rig, () => body(rig));
    });
  }
}

bool _nameFocused(WidgetTester t) {
  final Finder editable = find.descendant(
    of: find.byKey(homeNameFieldKey),
    matching: find.byType(EditableText),
  );
  return t.widget<EditableText>(editable).focusNode.hasFocus;
}

String _nameText(WidgetTester t) =>
    t.widget<TextField>(find.byKey(homeNameFieldKey)).controller!.text;

Finder _in(Key sheet, Finder what) =>
    find.descendant(of: find.byKey(sheet), matching: what);

void _expectNothingOpened(C701Rig r, String what) {
  expect(
    find.byKey(createRoomSheetKey, skipOffstage: false),
    findsNothing,
    reason: '$what opened the create sheet. ${r.repro}',
  );
  expect(
    find.byKey(joinSheetKey, skipOffstage: false),
    findsNothing,
    reason: '$what opened the join sheet. ${r.repro}',
  );
  expect(
    r.transports,
    isEmpty,
    reason: '$what opened a connection (sent ${r.sentTypes()}). ${r.repro}',
  );
}

void _expectNameRequired(C701Rig r, String what) {
  final Finder line = find.byKey(homeNameRequiredKey);
  expect(
    line,
    findsOneWidget,
    reason: '$what: expected the red line home-name-required. ${r.repro}',
  );
  expect(
    find.descendant(of: line, matching: find.text(r.loc.homeNameRequired)),
    findsOneWidget,
    reason:
        '$what: expected the line to read "${r.loc.homeNameRequired}". '
        '${r.repro}',
  );
  expect(
    find.descendant(of: line, matching: find.byType(Icon)),
    findsWidgets,
    reason:
        '$what: expected the refusal mark beside the line so colour is '
        'not the only signal. ${r.repro}',
  );
  expect(
    _nameFocused(r.tester),
    isTrue,
    reason: '$what: expected the name field to take focus. ${r.repro}',
  );
}

Future<void> _seedLastGame(WidgetTester tester, DateTime now) async {
  await tester.runAsync(() async {
    await SessionMemory.recordLastGame(
      LastGame(
        gameId: 'g-c701',
        verifyUrl: 'https://provefair.app/v/g-c701',
        finishedAt: now.subtract(const Duration(days: 1)),
        won: true,
      ),
    );
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    debugGoogleSignedInOverride = null;
  });

  group('home', () {
    row('home shows exactly the two buttons and nothing of the old join', (
      C701Rig r,
    ) async {
      await r.mount();
      final Finder create = find.byKey(createRoomButtonKey);
      final Finder join = find.byKey(joinGameButtonKey);
      expect(
        create,
        findsOneWidget,
        reason: 'no create-room-button. ${r.repro}',
      );
      expect(join, findsOneWidget, reason: 'no join-game-button. ${r.repro}');
      expect(
        find.descendant(
          of: create,
          matching: find.text(r.loc.homeCreateRoomButton),
        ),
        findsOneWidget,
        reason:
            'create button must read "${r.loc.homeCreateRoomButton}". ${r.repro}',
      );
      expect(
        find.descendant(
          of: join,
          matching: find.text(r.loc.homeJoinGameButton),
        ),
        findsOneWidget,
        reason:
            'join button must read "${r.loc.homeJoinGameButton}". ${r.repro}',
      );
      expect(
        find.descendant(of: create, matching: find.byIcon(Icons.add_rounded)),
        findsOneWidget,
        reason: 'create button must carry add_rounded. ${r.repro}',
      );
      expect(
        find.descendant(of: join, matching: find.byIcon(Icons.login_rounded)),
        findsOneWidget,
        reason: 'join button must carry login_rounded. ${r.repro}',
      );
      final Rect c = r.tester.getRect(create);
      final Rect j = r.tester.getRect(join);
      expect(
        (c.width - j.width).abs() < 0.5 && (c.height - j.height).abs() < 0.5,
        isTrue,
        reason:
            'the two buttons must be of equal width and height, got '
            'create ${c.size} and join ${j.size}. ${r.repro}',
      );
      expect(
        c.bottom <= j.top + 0.5 && (c.left - j.left).abs() < 0.5,
        isTrue,
        reason:
            'the buttons must be stacked, create first; got create $c, '
            'join $j. ${r.repro}',
      );
      expect(
        c.height >= 48,
        isTrue,
        reason: 'create is ${c.height} dp tall. ${r.repro}',
      );
      for (final Key gone in <Key>[
        roomCodeFieldKey,
        joinRoomButtonKey,
        homeJoinDividerKey,
        homeLastGameKey,
      ]) {
        expect(
          find.byKey(gone, skipOffstage: false),
          findsNothing,
          reason: '$gone must not be on home. ${r.repro}',
        );
      }
      final String dividerCopy = r.variant.lang == 'ar'
          ? 'أو انضم برمز'
          : 'or join with a code';
      expect(
        find.text(dividerCopy, skipOffstage: false),
        findsNothing,
        reason:
            'the divider copy "$dividerCopy" must be painted nowhere. ${r.repro}',
      );
      expect(
        find.text(r.loc.homeJoinRoomButton, skipOffstage: false),
        findsNothing,
        reason:
            'the old "${r.loc.homeJoinRoomButton}" button must be gone. ${r.repro}',
      );
    });

    row('last-game card stays hidden for a player not signed in with Google', (
      C701Rig r,
    ) async {
      final DateTime now = DateTime.utc(2026, 10, 12, 12);
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await _seedLastGame(r.tester, now);
      debugGoogleSignedInOverride = false;
      await r.mount(clock: () => now, keepPrefs: true);
      expect(
        find.byKey(homeLastGameKey, skipOffstage: false),
        findsNothing,
        reason:
            'a stored game must show no card without a Google sign-in. ${r.repro}',
      );
    });

    row('last-game card shows with the sign-in override on', (C701Rig r) async {
      final DateTime now = DateTime.utc(2026, 10, 12, 12);
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await _seedLastGame(r.tester, now);
      debugGoogleSignedInOverride = true;
      await r.mount(clock: () => now, keepPrefs: true);
      expect(
        find.byKey(homeLastGameKey),
        findsOneWidget,
        reason:
            'a stored game must show home-last-game with the override on. '
            '${r.repro}',
      );
      expect(
        find.byKey(createRoomButtonKey),
        findsOneWidget,
        reason: 'the card must not displace the two buttons. ${r.repro}',
      );
      expect(
        find.byKey(roomCodeFieldKey, skipOffstage: false),
        findsNothing,
        reason: 'the card must not bring the code field back. ${r.repro}',
      );
    });

    row('the name field starts empty with its label as the hint', (
      C701Rig r,
    ) async {
      await r.mount();
      final TextField field = r.tester.widget<TextField>(
        find.byKey(homeNameFieldKey),
      );
      expect(
        field.controller!.text,
        isEmpty,
        reason:
            'a first launch must not prefill a name, got "${field.controller!.text}". ${r.repro}',
      );
      expect(
        field.decoration?.hintText,
        r.loc.homeNameFieldLabel,
        reason:
            'the hint must be the label "${r.loc.homeNameFieldLabel}", got "${field.decoration?.hintText}". ${r.repro}',
      );
    });

    row('a saved name is prefilled', (C701Rig r) async {
      await r.mount(prefs: _savedNamePrefs);
      expect(
        _nameText(r.tester),
        _savedName,
        reason: 'the saved name must be prefilled. ${r.repro}',
      );
    });
  });

  group('name required (X226)', () {
    row('empty name: Create opens nothing, shows the line and takes focus', (
      C701Rig r,
    ) async {
      await r.mount();
      await r.tap(find.byKey(createRoomButtonKey), what: 'create-room-button');
      await r.tester.pump(const Duration(milliseconds: 400));
      _expectNothingOpened(r, 'Create with an empty name');
      _expectNameRequired(r, 'Create with an empty name');
    });

    row('empty name: Join opens nothing, shows the line and takes focus', (
      C701Rig r,
    ) async {
      await r.mount();
      await r.tap(find.byKey(joinGameButtonKey), what: 'join-game-button');
      await r.tester.pump(const Duration(milliseconds: 400));
      _expectNothingOpened(r, 'Join with an empty name');
      _expectNameRequired(r, 'Join with an empty name');
    });

    row('a name of only spaces counts as empty', (C701Rig r) async {
      await r.mount();
      await r.typeName('   ');
      await r.tap(find.byKey(createRoomButtonKey), what: 'create-room-button');
      await r.tester.pump(const Duration(milliseconds: 400));
      _expectNothingOpened(r, 'Create with a name of spaces');
      _expectNameRequired(r, 'Create with a name of spaces');
    });

    row('editing the name clears the line', (C701Rig r) async {
      await r.mount();
      await r.tap(find.byKey(joinGameButtonKey), what: 'join-game-button');
      await r.tester.pump(const Duration(milliseconds: 400));
      _expectNameRequired(r, 'Join with an empty name');
      await r.typeName('A');
      expect(
        find.byKey(homeNameRequiredKey),
        findsNothing,
        reason: 'the line must go once the field is edited. ${r.repro}',
      );
    });

    row('a refused tap shakes the name field once and it comes to rest', (
      C701Rig r,
    ) async {
      await r.mount();
      final Finder field = find.byKey(homeNameFieldKey);
      await r.tester.ensureVisible(find.byKey(createRoomButtonKey));
      await r.tester.pump();
      await r.tester.tap(find.byKey(createRoomButtonKey));
      final Rect rest = r.tester.getRect(field);
      double widest = 0;
      for (int i = 0; i < 40; i++) {
        await r.tester.pump(const Duration(milliseconds: 16));
        widest = widest < (r.tester.getRect(field).left - rest.left).abs()
            ? (r.tester.getRect(field).left - rest.left).abs()
            : widest;
      }
      await r.tester.pump(const Duration(seconds: 1));
      expect(
        widest > 0.5,
        isTrue,
        reason:
            'expected the name field to shake on a refused tap; it moved at most $widest dp. ${r.repro}',
      );
      expect(
        (r.tester.getRect(field).left - rest.left).abs() < 0.5,
        isTrue,
        reason: 'expected the field back at rest after the shake. ${r.repro}',
      );
    });

    row('a link with a saved name sends one join_room and needs no tap', (
      C701Rig r,
    ) async {
      final StreamController<Uri> links = StreamController<Uri>.broadcast();
      addTearDown(links.close);
      await r.mount(prefs: _savedNamePrefs, linkStream: () => links.stream);
      links.add(_link);
      await r.waitUntil(
        () => r.sent('join_room').isNotEmpty,
        'a join_room after the link',
      );
      await r.tester.pump(const Duration(milliseconds: 500));
      final List<Map<String, Object?>> joins = r.sent('join_room');
      expect(
        joins,
        hasLength(1),
        reason:
            'expected exactly one join_room, got ${joins.length}. ${r.repro}',
      );
      final Map<String, Object?> d = joins.single['d']! as Map<String, Object?>;
      expect(
        <String, Object?>{...d}..remove('install'),
        <String, Object?>{'link': _linkId, 'name': _savedName},
        reason:
            'join_room must carry the link id and the saved name, got $d. ${r.repro}',
      );
      expect(
        d['install'],
        isA<String>().having(
          (String s) => installShape.hasMatch(s),
          'install shape',
          isTrue,
        ),
        reason:
            'install must be 16..64 of [A-Za-z0-9_-], got ${d['install']}. ${r.repro}',
      );
      expect(
        r.taps,
        0,
        reason:
            'P5: a tapped link joins in 0 further taps, took ${r.taps}. ${r.repro}',
      );
      expect(
        find.byType(LobbyScreen),
        findsOneWidget,
        reason: 'expected the lobby after the link. ${r.repro}',
      );
    });

    row(
      'a link with no name waits, keeps the link and joins on a keyboard submit',
      (C701Rig r) async {
        final StreamController<Uri> links = StreamController<Uri>.broadcast();
        addTearDown(links.close);
        await r.mount(linkStream: () => links.stream);
        links.add(_link);
        await r.tester.pump();
        await r.tester.pump(const Duration(milliseconds: 600));
        expect(
          r.sent('join_room'),
          isEmpty,
          reason: 'a link with no name must send nothing yet. ${r.repro}',
        );
        expect(
          find.byType(LobbyScreen),
          findsNothing,
          reason: 'a link with no name must stay on home. ${r.repro}',
        );
        _expectNameRequired(r, 'a link with no name');
        await r.typeName(r.defaultName);
        await r.tester.pump(const Duration(milliseconds: 300));
        expect(
          r.sent('join_room'),
          isEmpty,
          reason: 'typing alone (no submit) must not join. ${r.repro}',
        );
        await r.tester.testTextInput.receiveAction(TextInputAction.done);
        await r.tester.pump();
        await r.waitUntil(
          () => r.sent('join_room').isNotEmpty,
          'a join_room after the name is submitted',
        );
        await r.tester.pump(const Duration(milliseconds: 500));
        final List<Map<String, Object?>> joins = r.sent('join_room');
        expect(
          joins,
          hasLength(1),
          reason: 'expected one join_room, got ${joins.length}. ${r.repro}',
        );
        final Map<String, Object?> d =
            joins.single['d']! as Map<String, Object?>;
        expect(
          d['link'],
          _linkId,
          reason: 'the kept link must be joined, got $d. ${r.repro}',
        );
        expect(
          d['name'],
          r.defaultName,
          reason: 'the submitted name must be sent, got $d. ${r.repro}',
        );
        expect(
          r.taps,
          0,
          reason:
              'P5: no button tap on the link path, took ${r.taps}. ${r.repro}',
        );
      },
    );

    row('a link that arrives cold with no name behaves the same', (
      C701Rig r,
    ) async {
      final Completer<Uri?> cold = Completer<Uri?>();
      await r.mount(initialLink: () => cold.future);
      cold.complete(_link);
      await r.tester.pump();
      await r.tester.pump(const Duration(milliseconds: 600));
      expect(
        r.sent('join_room'),
        isEmpty,
        reason: 'nothing may be sent without a name. ${r.repro}',
      );
      _expectNameRequired(r, 'a cold link with no name');
      await submitName(r.tester, r.defaultName);
      await r.waitUntil(
        () => r.sent('join_room').isNotEmpty,
        'a join_room after the name is submitted',
      );
      expect(
        r.sent('join_room').single['d'],
        containsPair('link', _linkId),
        reason: r.repro,
      );
    });
  });

  group('create sheet', () {
    row('both tiles are there, large, with their icon above one word', (
      C701Rig r,
    ) async {
      await r.mount();
      await r.typeName();
      await r.openCreateSheet();
      expect(
        _in(createRoomSheetKey, find.text(r.loc.createSheetTitle)),
        findsOneWidget,
        reason:
            'the sheet title "${r.loc.createSheetTitle}" is missing. ${r.repro}',
      );
      final Map<Key, (IconData, String)> tiles = <Key, (IconData, String)>{
        createOpenTileKey: (Icons.public_rounded, r.loc.createOpenTile),
        createFriendsTileKey: (Icons.group_rounded, r.loc.createFriendsTile),
      };
      final List<Rect> rects = <Rect>[];
      for (final MapEntry<Key, (IconData, String)> e in tiles.entries) {
        final Finder tile = find.byKey(e.key);
        expect(tile, findsOneWidget, reason: '${e.key} missing. ${r.repro}');
        final Rect rect = r.tester.getRect(tile);
        rects.add(rect);
        expect(
          rect.height >= 96,
          isTrue,
          reason: '${e.key} is ${rect.height} dp tall, need 96. ${r.repro}',
        );
        expect(
          rect.width >= 48,
          isTrue,
          reason: '${e.key} is ${rect.width} dp wide, need 48. ${r.repro}',
        );
        final Finder icon = find.descendant(
          of: tile,
          matching: find.byIcon(e.value.$1),
        );
        final Finder word = find.descendant(
          of: tile,
          matching: find.text(e.value.$2),
        );
        expect(
          icon,
          findsOneWidget,
          reason: '${e.key} must carry ${e.value.$1}. ${r.repro}',
        );
        expect(
          word,
          findsOneWidget,
          reason: '${e.key} must read "${e.value.$2}". ${r.repro}',
        );
        expect(
          r.tester.getRect(icon).bottom <= r.tester.getRect(word).top + 0.5,
          isTrue,
          reason: '${e.key}: the icon must sit above the word. ${r.repro}',
        );
      }
      expect(
        (rects[0].top - rects[1].top).abs() < 0.5 &&
            rects[0].overlaps(rects[1]) == false,
        isTrue,
        reason:
            'the tiles must sit side by side, got ${rects[0]} and ${rects[1]}. ${r.repro}',
      );
    });

    row('each tile has its screen reader label', (C701Rig r) async {
      final SemanticsHandle handle = r.tester.ensureSemantics();
      try {
        await r.mount();
        await r.typeName();
        await r.openCreateSheet();
        expect(
          find.bySemanticsLabel(r.loc.createOpenTileLabel),
          findsWidgets,
          reason:
              'missing semantics "${r.loc.createOpenTileLabel}". ${r.repro}',
        );
        expect(
          find.bySemanticsLabel(r.loc.createFriendsTileLabel),
          findsWidgets,
          reason:
              'missing semantics "${r.loc.createFriendsTileLabel}". ${r.repro}',
        );
      } finally {
        handle.dispose();
      }
    });

    row('the open tile sends create_room with open true in two taps', (
      C701Rig r,
    ) async {
      await r.mount();
      await r.typeName();
      await r.openCreateSheet();
      await r.tap(find.byKey(createOpenTileKey), what: 'create-open-tile');
      await r.waitUntil(
        () => r.sent('create_room').isNotEmpty,
        'create_room after the open tile',
      );
      await pumpUntilGone(
        r.tester,
        find.byKey(createRoomSheetKey),
        what: 'the create sheet',
      );
      final List<Map<String, Object?>> sent = r.sent('create_room');
      expect(
        sent,
        hasLength(1),
        reason: 'expected one create_room, got ${sent.length}. ${r.repro}',
      );
      final Map<String, Object?> d = sent.single['d']! as Map<String, Object?>;
      expect(
        d['open'],
        true,
        reason: 'open tile must send "open": true, got $d. ${r.repro}',
      );
      expect(
        d['name'],
        r.defaultName,
        reason: 'name must be the typed one, got $d. ${r.repro}',
      );
      expect(
        r.taps,
        2,
        reason:
            'P5: create an open room is Create plus one tile, took ${r.taps}. ${r.repro}',
      );
    });

    row('the friends tile sends create_room with open false in two taps', (
      C701Rig r,
    ) async {
      await r.mount();
      await r.typeName();
      await r.openCreateSheet();
      await r.tap(
        find.byKey(createFriendsTileKey),
        what: 'create-friends-tile',
      );
      await r.waitUntil(
        () => r.sent('create_room').isNotEmpty,
        'create_room after the friends tile',
      );
      final List<Map<String, Object?>> sent = r.sent('create_room');
      expect(
        sent,
        hasLength(1),
        reason: 'expected one create_room, got ${sent.length}. ${r.repro}',
      );
      final Map<String, Object?> d = sent.single['d']! as Map<String, Object?>;
      expect(
        d['open'],
        false,
        reason: 'friends tile must send "open": false, got $d. ${r.repro}',
      );
      expect(
        d['name'],
        r.defaultName,
        reason: 'name must be the typed one, got $d. ${r.repro}',
      );
      expect(
        r.taps,
        2,
        reason:
            'P5: create a friends room is Create plus one tile, took ${r.taps}. ${r.repro}',
      );
    });

    row('two quick taps on a tile create one room', (C701Rig r) async {
      await r.mount();
      await r.typeName();
      await r.openCreateSheet();
      final Finder tile = find.byKey(createFriendsTileKey);
      await r.tester.tap(tile);
      await r.tester.tap(tile, warnIfMissed: false);
      await r.tester.pump();
      await r.tester.pump(const Duration(milliseconds: 600));
      await r.waitUntil(() => r.sent('create_room').isNotEmpty, 'create_room');
      await r.tester.pump(const Duration(seconds: 1));
      expect(
        r.sent('create_room'),
        hasLength(1),
        reason:
            'a double tap on a tile must create exactly one room. ${r.repro}',
      );
    });

    row('back closes the sheet and creates nothing', (C701Rig r) async {
      await r.mount();
      await r.typeName();
      await r.openCreateSheet();
      await backOutOfSheet(r.tester, createRoomSheetKey);
      await r.tester.pump(const Duration(seconds: 1));
      expect(
        r.sent('create_room'),
        isEmpty,
        reason: 'back must create nothing. ${r.repro}',
      );
      expect(
        r.transports,
        isEmpty,
        reason: 'back must open no connection. ${r.repro}',
      );
      expect(
        find.byKey(createRoomButtonKey),
        findsOneWidget,
        reason: 'home must be back. ${r.repro}',
      );
    });

    row('a tap outside closes the sheet and creates nothing', (
      C701Rig r,
    ) async {
      await r.mount();
      await r.typeName();
      await r.openCreateSheet();
      await r.tester.tapAt(const Offset(4, 4));
      await r.tester.pump();
      await pumpUntilGone(
        r.tester,
        find.byKey(createRoomSheetKey),
        what: 'the create sheet after a tap outside',
      );
      await r.tester.pump(const Duration(seconds: 1));
      expect(
        r.sent('create_room'),
        isEmpty,
        reason: 'a tap outside must create nothing. ${r.repro}',
      );
      expect(
        r.transports,
        isEmpty,
        reason: 'a tap outside must open no connection. ${r.repro}',
      );
    });
  });

  group('join sheet', () {
    row('both tiles are there, large, with their icon above one word', (
      C701Rig r,
    ) async {
      await r.mount();
      await r.typeName();
      await r.openJoinSheet();
      expect(
        _in(joinSheetKey, find.text(r.loc.joinSheetTitle)),
        findsOneWidget,
        reason:
            'the sheet title "${r.loc.joinSheetTitle}" is missing. ${r.repro}',
      );
      final Map<Key, (IconData, String)> tiles = <Key, (IconData, String)>{
        joinCodeTileKey: (Icons.dialpad_rounded, r.loc.joinCodeTile),
        joinRandomTileKey: (Icons.casino_rounded, r.loc.joinRandomTile),
      };
      for (final MapEntry<Key, (IconData, String)> e in tiles.entries) {
        final Finder tile = find.byKey(e.key);
        expect(tile, findsOneWidget, reason: '${e.key} missing. ${r.repro}');
        final Rect rect = r.tester.getRect(tile);
        expect(
          rect.height >= 96,
          isTrue,
          reason: '${e.key} is ${rect.height} dp tall, need 96. ${r.repro}',
        );
        expect(
          rect.width >= 48,
          isTrue,
          reason: '${e.key} is ${rect.width} dp wide, need 48. ${r.repro}',
        );
        final Finder icon = find.descendant(
          of: tile,
          matching: find.byIcon(e.value.$1),
        );
        final Finder word = find.descendant(
          of: tile,
          matching: find.text(e.value.$2),
        );
        expect(
          icon,
          findsOneWidget,
          reason: '${e.key} must carry ${e.value.$1}. ${r.repro}',
        );
        expect(
          word,
          findsOneWidget,
          reason: '${e.key} must read "${e.value.$2}". ${r.repro}',
        );
        expect(
          r.tester.getRect(icon).bottom <= r.tester.getRect(word).top + 0.5,
          isTrue,
          reason: '${e.key}: the icon must sit above the word. ${r.repro}',
        );
      }
    });

    row('the code tile swaps the same sheet to the code entry', (
      C701Rig r,
    ) async {
      await r.mount();
      await r.typeName();
      await r.openJoinSheet();
      final int sheetsBefore = find.byType(BottomSheet).evaluate().length;
      await r.tap(find.byKey(joinCodeTileKey), what: 'join-code-tile');
      await pumpUntilAtRest(
        r.tester,
        find.byKey(roomCodeFieldKey),
        what: 'room-code-field. ${r.repro}',
      );
      expect(
        _in(joinSheetKey, find.byKey(roomCodeFieldKey)),
        findsOneWidget,
        reason: 'room-code-field must live inside join-sheet. ${r.repro}',
      );
      expect(
        find.byType(BottomSheet).evaluate().length,
        sheetsBefore,
        reason:
            'the swap must not push a second sheet (had $sheetsBefore). ${r.repro}',
      );
      expect(
        find.byKey(roomCodeFieldKey).evaluate().length,
        1,
        reason: 'one room-code-field expected. ${r.repro}',
      );
      final EditableText editable = r.tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(roomCodeFieldKey),
          matching: find.byType(EditableText),
        ),
      );
      expect(
        editable.focusNode.hasFocus,
        isTrue,
        reason: 'the code field must autofocus. ${r.repro}',
      );
    });

    row('a typed code sends the join_room the old home sent, in three taps', (
      C701Rig r,
    ) async {
      await r.mount();
      await r.typeName();
      await r.openCodeEntryCounted();
      await r.tester.enterText(find.byKey(roomCodeFieldKey), _goodCode);
      await r.tester.pump();
      await r.tap(find.byKey(joinRoomButtonKey), what: 'join-room-button');
      await r.waitUntil(
        () => r.sent('join_room').isNotEmpty,
        'join_room after the code',
      );
      final List<Map<String, Object?>> joins = r.sent('join_room');
      expect(
        joins,
        hasLength(1),
        reason: 'expected one join_room, got ${joins.length}. ${r.repro}',
      );
      final Map<String, Object?> d = joins.single['d']! as Map<String, Object?>;
      expect(<String, Object?>{...d}..remove('install'), <String, Object?>{
        'code': _goodCode,
        'name': r.defaultName,
      }, reason: 'join_room must carry code and name, got $d. ${r.repro}');
      expect(
        d['install'],
        isA<String>().having(
          (String s) => installShape.hasMatch(s),
          'install shape',
          isTrue,
        ),
        reason: 'install shape, got ${d['install']}. ${r.repro}',
      );
      expect(
        r.taps,
        3,
        reason:
            'P5: join by code is Join, code tile, Join, took ${r.taps}. ${r.repro}',
      );
    });

    row('the same formatter normalises a lower case code', (C701Rig r) async {
      await r.mount();
      await r.typeName();
      await r.openCodeEntryCounted();
      await r.tester.enterText(
        find.byKey(roomCodeFieldKey),
        _goodCode.toLowerCase(),
      );
      await r.tester.pump();
      await r.tap(find.byKey(joinRoomButtonKey), what: 'join-room-button');
      await r.waitUntil(
        () => r.sent('join_room').isNotEmpty,
        'join_room after the code',
      );
      expect(
        (r.sent('join_room').single['d']! as Map<String, Object?>)['code'],
        _goodCode,
        reason: 'a lower case code must be sent upper case. ${r.repro}',
      );
    });

    row('an invalid code shows its line in the sheet and sends nothing', (
      C701Rig r,
    ) async {
      await r.mount();
      await r.typeName();
      await r.openCodeEntryCounted();
      await r.tester.enterText(find.byKey(roomCodeFieldKey), _badCode);
      await r.tester.pump();
      await r.tap(find.byKey(joinRoomButtonKey), what: 'join-room-button');
      await r.tester.pump(const Duration(milliseconds: 400));
      expect(
        _in(joinSheetKey, find.text(r.loc.homeRoomCodeInvalid)),
        findsOneWidget,
        reason:
            'expected "${r.loc.homeRoomCodeInvalid}" inside the join sheet. ${r.repro}',
      );
      expect(
        r.sent('join_room'),
        isEmpty,
        reason: 'an invalid code must send nothing. ${r.repro}',
      );
    });

    row('a refused code ban shows its notice in the join sheet', (
      C701Rig r,
    ) async {
      await r.mount();
      await r.typeName();
      await r.openCodeEntryCounted();
      await r.tester.enterText(find.byKey(roomCodeFieldKey), _goodCode);
      await r.tester.pump();
      await r.tap(find.byKey(joinRoomButtonKey), what: 'join-room-button');
      await r.waitUntil(
        () => r.sent('join_room').isNotEmpty,
        'join_room after the code',
      );
      await r.push('error', <String, Object?>{
        'code': 'CODE_BANNED',
        'message': 'code joins are blocked',
        'ban': <String, Object?>{
          'scope': 'device',
          'until_ms': 4102444800000,
          'level': 1,
          'next_ms': 7 * 86400000,
        },
      }, re: r.idOfLast('join_room'));
      await r.waitUntil(
        () => find.byKey(const Key('code-ban-notice')).evaluate().isNotEmpty,
        'the code ban notice',
      );
      expect(
        _in(joinSheetKey, find.byKey(const Key('code-ban-notice'))),
        findsOneWidget,
        reason:
            'the ban notice must show IN the join sheet, not behind it '
            '(join sheet up: ${find.byKey(joinSheetKey).evaluate().isNotEmpty}, '
            'notice on screen: ${find.byKey(const Key('code-ban-notice')).evaluate().isNotEmpty}). '
            '${r.repro}',
      );
    });

    row('the random tile sends find_game with name and install in two taps', (
      C701Rig r,
    ) async {
      await r.mount();
      await r.typeName();
      await r.enterQueue();
      final List<Map<String, Object?>> finds = r.sent('find_game');
      expect(
        finds,
        hasLength(1),
        reason: 'expected one find_game, got ${finds.length}. ${r.repro}',
      );
      final Map<String, Object?> d = finds.single['d']! as Map<String, Object?>;
      expect(
        d.keys.toSet(),
        <String>{'name', 'install'},
        reason:
            'first find_game carries name and install only, got $d. ${r.repro}',
      );
      expect(
        d['name'],
        r.defaultName,
        reason: 'name must be the typed one, got $d. ${r.repro}',
      );
      expect(
        d['install'],
        isA<String>().having(
          (String s) => installShape.hasMatch(s),
          'install shape',
          isTrue,
        ),
        reason: 'install shape, got ${d['install']}. ${r.repro}',
      );
      await pumpUntilGone(
        r.tester,
        find.byKey(joinSheetKey),
        what: 'the join sheet after the random tile',
      );
      expect(
        r.taps,
        2,
        reason:
            'P5: random players is Join plus one tile, took ${r.taps}. ${r.repro}',
      );
    });

    row('back closes the join sheet and sends nothing', (C701Rig r) async {
      await r.mount();
      await r.typeName();
      await r.openJoinSheet();
      await backOutOfSheet(r.tester, joinSheetKey);
      await r.tester.pump(const Duration(seconds: 1));
      expect(
        r.transports,
        isEmpty,
        reason: 'back must open no connection. ${r.repro}',
      );
    });
  });

  group('no overflow at text scale 1.3', () {
    row('home', (C701Rig r) async {
      await r.mount();
      r.expectNoOverflow(
        'home',
        keys: <Key>[createRoomButtonKey, joinGameButtonKey, homeNameFieldKey],
      );
    }, variants: kLargeTextVariants);

    row('home with the name-required line', (C701Rig r) async {
      await r.mount();
      await r.tap(find.byKey(createRoomButtonKey), what: 'create-room-button');
      await r.tester.pump(const Duration(milliseconds: 400));
      r.expectNoOverflow(
        'home with the name line',
        keys: <Key>[homeNameRequiredKey],
      );
    }, variants: kLargeTextVariants);

    row('create sheet', (C701Rig r) async {
      await r.mount();
      await r.typeName();
      await r.openCreateSheet();
      r.expectNoOverflow(
        'create sheet',
        keys: <Key>[createOpenTileKey, createFriendsTileKey],
      );
    }, variants: kLargeTextVariants);

    row('join sheet', (C701Rig r) async {
      await r.mount();
      await r.typeName();
      await r.openJoinSheet();
      r.expectNoOverflow(
        'join sheet',
        keys: <Key>[joinCodeTileKey, joinRandomTileKey],
      );
    }, variants: kLargeTextVariants);

    row('code entry', (C701Rig r) async {
      await r.mount();
      await r.typeName();
      await r.openCodeEntryCounted();
      await r.tester.enterText(find.byKey(roomCodeFieldKey), _goodCode);
      await r.tester.pump(const Duration(milliseconds: 300));
      r.expectNoOverflow(
        'code entry',
        keys: <Key>[roomCodeFieldKey, joinRoomButtonKey],
      );
    }, variants: kLargeTextVariants);

    row(
      'code entry: the Join button can be tapped and sends join_room',
      (C701Rig r) async {
        await r.mount();
        await r.typeName();
        await r.openCodeEntryCounted();
        await r.tester.enterText(find.byKey(roomCodeFieldKey), _goodCode);
        await r.tester.pump(const Duration(milliseconds: 400));
        final Finder join = find.byKey(joinRoomButtonKey);
        await pumpUntilAtRest(r.tester, join, what: 'join-room-button');
        await r.tester.ensureVisible(join);
        await r.tester.pump();
        await r.tester.tap(join, warnIfMissed: false);
        await r.tester.pump();
        await r.waitUntil(
          () => r.sent('join_room').isNotEmpty,
          'a join_room: join-room-button at ${r.tester.getRect(join)} did not '
          'receive the tap (something covers it or the sheet clips it)',
        );
      },
      variants: <C701Variant>[
        ...kLargeTextVariants,
        for (final C701Variant v in kVariants) v.withScale(2.0),
      ],
    );

    row('code entry with the keyboard up', (C701Rig r) async {
      await r.mount();
      await r.typeName();
      await r.openCodeEntryCounted();
      r.tester.view.viewInsets = FakeViewPadding(
        bottom: r.variant.size.height * 0.4,
      );
      await r.tester.enterText(find.byKey(roomCodeFieldKey), _goodCode);
      await r.tester.pump(const Duration(milliseconds: 500));
      r.expectNoOverflow(
        'code entry with the keyboard up',
        keys: <Key>[roomCodeFieldKey],
      );
      final Rect field = r.tester.getRect(find.byKey(roomCodeFieldKey));
      expect(
        field.bottom <= r.variant.size.height * 0.6 + 0.5,
        isTrue,
        reason:
            'the sheet must rise with the keyboard: the code field ends at ${field.bottom} dp, the keyboard starts at ${r.variant.size.height * 0.6}. ${r.repro}',
      );
    }, variants: kLargeTextVariants);
  });
}
