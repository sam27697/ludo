// Steps for driving the two-button home of order 701 from the integration
// tests. The shared steps live in test/support/home_flow.dart (a relative
// import reaches them from here); this file adds the two the integration
// rigs need on top: a name when the field is empty, and typing a room code
// into the join sheet's code entry.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../test/support/home_flow.dart';

export '../../test/support/home_flow.dart';

/// Types the localised default name into `home-name-field` when it is
/// empty, so a Create or Join that used to send the default name still can.
Future<void> ensureName(WidgetTester t) async {
  final Finder field = find.byKey(homeNameFieldKey);
  expect(
    field,
    findsOneWidget,
    reason: 'home_flow.ensureName: expected one home-name-field on home',
  );
  final TextField widget = t.widget<TextField>(field);
  if ((widget.controller?.text ?? '').trim().isNotEmpty) {
    return;
  }
  await enterOldDefaultName(t);
}

/// Types [code] into the room code field, opening the join sheet's code
/// entry first when it is not open (with a name, X226).
Future<void> enterCodeInEntry(WidgetTester t, String code) async {
  if (find.byKey(roomCodeFieldKey).evaluate().isEmpty) {
    await ensureName(t);
    await openCodeEntry(t);
  }
  await t.enterText(find.byKey(roomCodeFieldKey), code);
}

/// Taps `create-room-button` as a player with a name: the create sheet, the
/// friends-only tile (or the open tile when [open]). The create flow that
/// follows is left to the caller's own pumps.
Future<void> createViaSheet(WidgetTester t, {bool open = false}) async {
  await ensureName(t);
  await t.ensureVisible(find.byKey(createRoomButtonKey));
  await t.pump();
  await tapCreateRoom(t, open: open);
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}
