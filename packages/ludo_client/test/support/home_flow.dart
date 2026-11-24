// Shared steps for driving the two-button home of order 701.
//
// Home has exactly two buttons: `create-room-button` opens the create sheet
// (`create-room-sheet`, tiles `create-open-tile` and `create-friends-tile`)
// and `join-game-button` opens the join sheet (`join-sheet`, tiles
// `join-code-tile` and `join-random-tile`). The room code field and
// `join-room-button` live behind `join-code-tile`. A name is required before
// either button opens anything.
//
// Every wait below is on a condition (a widget found, gone, or at rest), in
// bounded 50 ms steps, never pumpAndSettle: the create path can land on a
// lobby whose connecting spinner never settles. Each wait fails with what it
// was waiting for and how long it waited.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const Key createRoomButtonKey = Key('create-room-button');
const Key joinGameButtonKey = Key('join-game-button');
const Key createRoomSheetKey = Key('create-room-sheet');
const Key createOpenTileKey = Key('create-open-tile');
const Key createFriendsTileKey = Key('create-friends-tile');
const Key joinSheetKey = Key('join-sheet');
const Key joinCodeTileKey = Key('join-code-tile');
const Key joinRandomTileKey = Key('join-random-tile');
const Key roomCodeFieldKey = Key('room-code-field');
const Key joinRoomButtonKey = Key('join-room-button');
const Key homeNameFieldKey = Key('home-name-field');
const Key homeNameRequiredKey = Key('home-name-required');

const Duration _step = Duration(milliseconds: 50);
const int _maxSteps = 60; // 3 s of fake time

/// Pumps in [_step]s until [finder] finds at least one widget.
Future<void> pumpUntilFound(
  WidgetTester t,
  Finder finder, {
  required String what,
}) async {
  for (int i = 0; i < _maxSteps; i++) {
    if (finder.evaluate().isNotEmpty) return;
    await t.pump(_step);
  }
  if (finder.evaluate().isNotEmpty) return;
  fail(
    'home_flow: waited ${_step.inMilliseconds * _maxSteps} ms for $what '
    '($finder) and it never appeared',
  );
}

/// Pumps in [_step]s until [finder] finds nothing.
Future<void> pumpUntilGone(
  WidgetTester t,
  Finder finder, {
  required String what,
}) async {
  for (int i = 0; i < _maxSteps; i++) {
    if (finder.evaluate().isEmpty) return;
    await t.pump(_step);
  }
  if (finder.evaluate().isEmpty) return;
  fail(
    'home_flow: waited ${_step.inMilliseconds * _maxSteps} ms for $what '
    '($finder) to go and it is still there',
  );
}

/// Pumps in [_step]s until the single widget at [finder] holds the same rect
/// over two consecutive frames: a sheet or a swapped content has finished
/// moving and a tap lands where the finder says.
Future<void> pumpUntilAtRest(
  WidgetTester t,
  Finder finder, {
  required String what,
}) async {
  await pumpUntilFound(t, finder, what: what);
  Rect last = t.getRect(finder.first);
  for (int i = 0; i < _maxSteps; i++) {
    await t.pump(_step);
    final Rect now = t.getRect(finder.first);
    if (now == last) return;
    last = now;
  }
  fail(
    'home_flow: $what ($finder) was still moving after '
    '${_step.inMilliseconds * _maxSteps} ms; last rect $last',
  );
}

/// The localised default name the old home prefilled and sent for an empty
/// field (`homeDefaultPlayerName`): "Player" in English, «لاعب» in Arabic.
/// Migrated tests type it so the frames they expect stay the same.
String oldDefaultName(String languageCode) =>
    languageCode == 'ar' ? 'لاعب' : 'Player';

/// Types [name] into the home name field.
///
/// For tests that used to create or join with an empty field and relied on
/// the localised default name: the new home sends nothing without a name, so
/// they type the name their expected frames already carry ("Player" in
/// English, «لاعب» in Arabic).
Future<void> enterName(WidgetTester t, String name) async {
  final Finder field = find.byKey(homeNameFieldKey);
  expect(
    field,
    findsOneWidget,
    reason: 'home_flow.enterName: expected one home-name-field on home',
  );
  await t.enterText(field, name);
  await t.pump();
}

/// Types [name] into the home name field and submits it from the keyboard
/// (the `done` action). A room link that arrived with no name waits on
/// home for exactly this, then joins.
Future<void> submitName(WidgetTester t, String name) async {
  await enterName(t, name);
  await t.testTextInput.receiveAction(TextInputAction.done);
  await t.pump();
}

/// Types [oldDefaultName] for the locale home is showing.
Future<void> enterOldDefaultName(WidgetTester t) async {
  final Finder field = find.byKey(homeNameFieldKey);
  expect(
    field,
    findsOneWidget,
    reason: 'home_flow.enterOldDefaultName: expected one home-name-field',
  );
  final String languageCode = Localizations.localeOf(t.element(field))
      .languageCode;
  await enterName(t, oldDefaultName(languageCode));
}

/// Taps `create-room-button`, waits for the create sheet to come to rest,
/// taps the friends-only tile (or the open tile when [open]) and waits for
/// the sheet to leave. Whatever the tile starts (the create flow) is left to
/// the caller's own pumps, exactly as after the old one-tap Create.
Future<void> tapCreateRoom(WidgetTester t, {bool open = false}) async {
  final Finder button = find.byKey(createRoomButtonKey);
  expect(
    button,
    findsOneWidget,
    reason: 'home_flow.tapCreateRoom: expected one create-room-button on home',
  );
  await t.tap(button);
  await t.pump();
  final Finder tile = find.byKey(
    open ? createOpenTileKey : createFriendsTileKey,
  );
  await pumpUntilAtRest(
    t,
    tile,
    what:
        '${open ? 'create-open-tile' : 'create-friends-tile'} in the create '
        'sheet after tapping create-room-button (an empty name opens nothing: '
        'did the test type a name first?)',
  );
  await t.tap(tile);
  await t.pump();
  await pumpUntilGone(
    t,
    find.byKey(createRoomSheetKey),
    what: 'create-room-sheet after a tile tap',
  );
}

/// Sends the system back gesture and waits for the sheet at [sheetKey] to
/// leave.
Future<void> backOutOfSheet(WidgetTester t, Key sheetKey) async {
  await t.binding.handlePopRoute();
  await t.pump();
  await pumpUntilGone(
    t,
    find.byKey(sheetKey),
    what: '$sheetKey after the system back',
  );
}

/// Taps `join-game-button`, waits for the join sheet, taps `join-code-tile`
/// and waits until `room-code-field` is in the sheet and at rest.
Future<void> openCodeEntry(WidgetTester t) async {
  final Finder button = find.byKey(joinGameButtonKey);
  expect(
    button,
    findsOneWidget,
    reason: 'home_flow.openCodeEntry: expected one join-game-button on home',
  );
  await t.tap(button);
  await t.pump();
  final Finder tile = find.byKey(joinCodeTileKey);
  await pumpUntilAtRest(
    t,
    tile,
    what:
        'join-code-tile in the join sheet after tapping join-game-button (an '
        'empty name opens nothing: did the test type a name first?)',
  );
  await t.tap(tile);
  await t.pump();
  await pumpUntilAtRest(
    t,
    find.byKey(roomCodeFieldKey),
    what: 'room-code-field in the join sheet after tapping join-code-tile',
  );
}
