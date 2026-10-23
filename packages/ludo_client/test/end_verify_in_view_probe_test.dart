// Order 425, amended by order 429 for C-429 and by order 436 for C-436.
// Probe, not a fix: does the end card's fairness line (`loc.endFairLine`),
// its one-tap Check-the-rolls button (`game-screen-verify-button`) and
// `end-card-fair-hint` sit wholly on screen, with the scroll at its start,
// in every end-card variant, on shapes s1/s2/s3? A red case here is the
// finding; it stays red.
//
// C-429 D3's verdict set: every s1/s2/s3 x en/ar variant at scale 1.0 (order
// 425's own table), plus `win` and `lose` on s2 at scale 1.3, en and ar, are
// asserted.
//
// C-436 D3 extends that set by ten cases: friend_left, everyone_left,
// offline, rematch_gone and rematch_ask on s2 at scale 1.3, en and ar. The
// verify button, the fairness line and the hint must sit wholly inside the
// viewport with the scroll at its start, asserted exactly the way the C-429
// verdict set is. A status line in the dock costs the scroll viewport about
// 38 px, which is what pushes the verify button under the dock today; these
// ten are red until the end card gives that height back.
//
// C-436 D4, the stated limit: `offline_friend_left` on s2 at 1.3 (two status
// lines at once, and the phone is offline, so the verify page cannot load
// from that state anyway) stays report-only and keeps printing its own
// ENDVERIFY line, unasserted. Every other s2 1.3 case (ended, rematch_waiting,
// rematch_waiting_host_start, in both locales) also stays report-only and
// keeps printing its own ENDVERIFY line exactly as order 425 left it; those
// are X74's own open residue, not this file's concern to close.
//
// C-429 D4: on the win card, `end-card-celebration` stays present, its
// painted child (the `CustomPaint` the animated burst builds, or the
// `Container` the reduced-motion branch builds in its place, found as a
// descendant of the keyed widget) measures 196 x 196 within 0.5, and that
// child's own centre sits within 1 px of `game-screen-winner`'s centre. This
// file asserts D4 on `win`, s2, scale 1.0, en and ar (inside the verdict
// matrix below, measured after the same bounded celebration pumps every
// other celebrating case already runs past), and once more under one extra
// reduced-motion mount (`win`, s2, scale 1.0, `MediaQuery.disableAnimations`
// true, the `MaterialApp.builder` + `MediaQuery(...).copyWith` idiom
// test/home_motion_test.dart's own `_harness` uses, not imported, copied by
// hand the same way the rest of this file's harness is).
//
// The shapes, the insets, the devicePixelRatio, the font load, the theme,
// the host harness and the `_visibilityProblem` / hit-test logic are copied
// by hand from test/next_step_in_view_end_test.dart (order 393/398's own
// probe), not imported: this file imports nothing from another test file
// except test/net/fake_transport.dart, per this order's own file list.
//
// Every variant below is reached through frames the server really sends,
// read off docs/PROTOCOL.md sections 14, 16 and 18, and off
// test/leave_table_end_card_test.dart, test/rematch_client_test.dart,
// test/finished_card_survives_rematch_test.dart and
// lib/src/game_screen.dart's own `_gameOverBody`. GameScreen is mounted over
// a real RoomController and FakeTransport; the finished body is always
// GameScreen's own EndCardFrame, never a bare EndCard built by this file.
// One mount per case.
//
// `ended` (end-card-ended): docs/PROTOCOL.md section 14.2 says `winner` is
// "null in LOBBY and PLAYING, an integer seat in FINISHED", so a live game
// never finishes without a resolvable winner. But `lib/src/game_screen.dart`
// resolves the winner's name against `finished.seats`, not against the
// winner seat number alone, and section 18 rule 3 (1101-1103) lets
// `leave_room` in FINISHED free a seat entirely -- removed from `seats`,
// not merely marked disconnected. A device that was never connected while
// the game played, and whose first `resume` reply lands after the winner
// already left, gets a FINISHED snapshot whose own `winner` seat is absent
// from its own `seats`: `lib/src/net/room_controller.dart`'s `resumeRoom`
// records that very snapshot as `lastFinished` (it calls
// `_recordLastFinished` unconditionally on success, unlike `createRoom`'s
// `_openFresh`, which clears it), so `_gameOverBody`'s `finished` stays that
// snapshot and `winnerName` never resolves. That reaches end-card-ended
// through a real `resume` reply, so this file does not skip it.
//
// Every variant needing a rematch LOBBY or a departed seat connects through
// a live PLAYING room first, then an unsolicited `room` push into FINISHED
// (never `createRoom`'s own reply landing already FINISHED): `_openFresh`
// clears `lastFinished` unconditionally, so a direct FINISHED reply would
// leave it null and the first rematch LOBBY push (PROTOCOL 16.2 rule 1
// nulls `winner`) would misread as `ended` instead of the variant asked
// for -- the same trap test/finished_card_survives_rematch_test.dart's own
// header documents for case 5. The unsolicited push goes through
// `_applyRoomFrame`, which does record `lastFinished`.
//
// Every case computes `GameStats` from an empty local transcript (no frames
// were ever played through this harness), which is always incomplete, so
// `_gameOverBody` always schedules one `game_log` request once the end card
// is first up, connected, in FINISHED. `_settleGameLog` answers it with an
// empty, structurally valid reply (or lets a transport that is about to
// close fail it automatically) so no 10-second request timer is ever left
// pending at the end of a case, per this order's own standing rule.
//
// Ambiguities hit while writing this file, reported rather than invented
// around:
//
//   1. The order's ENDVERIFY line asks for `line=<..>` and `hint=<..>`
//      without saying GREEN/RED explicitly the way `verify=<GREEN|RED>`
//      does; goal items 2 and 3 read "is wholly inside the same bounds"
//      with no hit-test mentioned (unlike item 1, which says "and a hit
//      test ... reaches it"), so this file reads `line` and `hint` as
//      GREEN/RED on bounds alone ((a) safe area, (b) scroll viewport),
//      never hit-tested, and prints them the same GREEN/RED way `verify`
//      is printed.
//   2. `dockTop=<px>` is not given a widget to measure from: `end_card.dart`
//      gives the dock no key, and `EndCardFrame.build`'s own `Column` puts
//      the scroll's `Expanded` directly above the dock with nothing between
//      them. This file reads `dockTop` as the same render box this file
//      already finds for check (b), the Scrollable ancestor's own bottom
//      edge, since that edge and the dock's top edge are the same point by
//      that Column's own construction. If a later change puts spacing or a
//      divider between them, this reading of `dockTop` goes stale with it.
//   3. Variant `ended` structurally cannot carry a `rematch`, a departed
//      seat or an offline flag at once without changing what makes it
//      `ended` in the first place (losing the "winner's own seat was never
//      known to this device" shape above), so it is the one variant this
//      file reaches alone, with no combination.
//
// Ambiguities hit while amending this file for order 429 / C-429 D3-D4,
// reported rather than invented around:
//
//   4. Order 429 names the D4 centre target as `game-screen-winner`; C-429's
//      own D4 text names it "the title's centre". `end_card.dart` keys the
//      win-card title `game-screen-winner` (also confirmed by
//      test/end_card_test.dart's own `_titleText` comment, "The title key
//      (`game-screen-winner`)"), so these two wordings name the same
//      widget; this file reads them as one requirement, not two.
//   5. Neither order 429 nor C-429 names which locale carries the "one
//      extra reduced-motion mount" D4 asks for. This file mounts it at
//      `en`; the en and ar win mounts already in the verdict matrix at s2
//      1.0 cover D4 under full motion in both locales, and D4's own
//      geometry (a fixed-size painted circle centred on a title, locale
//      only changing the title's own text) gives no reason to expect the
//      reduced-motion branch to differ by locale the animated branch
//      doesn't already rule out.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart'
    show HitTestEntry, HitTestResult, HitTestTarget;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart' show buildAppTheme;

import 'net/fake_transport.dart';

// --- shapes, copied by hand from test/next_step_in_view_end_test.dart's
// --- own s1/s2/s3 (the order asks for exactly these three) -----------------

class _Shape {
  const _Shape({
    required this.id,
    required this.width,
    required this.height,
    required this.dpr,
    required this.topInset,
    required this.bottomInset,
  });

  final String id;
  final double width;
  final double height;
  final double dpr;
  final double topInset;
  final double bottomInset;

  Size get physical => Size(width * dpr, height * dpr);

  double get safeBottom => height - bottomInset;
}

const _Shape _s1 = _Shape(
  id: 's1',
  width: 360,
  height: 616,
  dpr: 3,
  topInset: 24,
  bottomInset: 0,
);
const _Shape _s2 = _Shape(
  id: 's2',
  width: 360,
  height: 640,
  dpr: 3,
  topInset: 24,
  bottomInset: 48,
);
const _Shape _s3 = _Shape(
  id: 's3',
  width: 360,
  height: 780,
  dpr: 3,
  topInset: 32,
  bottomInset: 24,
);
const List<_Shape> _shapes = <_Shape>[_s1, _s2, _s3];
const List<Locale> _locales = <Locale>[Locale('en'), Locale('ar')];

const double _fitSlop = 0.5;

// --- keys the contract names -------------------------------------------

const Key _verifyKey = Key('game-screen-verify-button');
const Key _fairHintKey = Key('end-card-fair-hint');
const Key _celebrationKey = Key('end-card-celebration');
const Key _winnerTitleKey = Key('game-screen-winner');
const Key _winKey = Key('end-card-win');
const Key _loseKey = Key('end-card-lose');
const Key _endedKey = Key('end-card-ended');
const Key _leftKey = Key('end-card-left');
const Key _offlineKey = Key('end-card-offline');
const Key _rematchKey = Key('end-card-rematch');
const Key _rematchWaitingKey = Key('end-card-rematch-waiting');
const Key _rematchAskKey = Key('end-card-rematch-ask');
const Key _rematchStartKey = Key('end-card-rematch-start');
const Key _rematchGoneKey = Key('end-card-rematch-gone');
const Key _newRoomKey = Key('game-screen-new-room-button');
const Key _staleTableKey = Key('game-screen-stale-table');

/// Every dock/panel key one variant might show, used to build each
/// variant's own negative set: present minus this pool is absent.
const List<Key> _allIdentityKeys = <Key>[
  _winKey,
  _loseKey,
  _endedKey,
  _leftKey,
  _offlineKey,
  _rematchKey,
  _rematchWaitingKey,
  _rematchAskKey,
  _rematchStartKey,
  _rematchGoneKey,
];

// --- variants ---------------------------------------------------------

enum _Variant {
  win,
  lose,
  ended,
  friendLeft,
  everyoneLeft,
  offline,
  offlineFriendLeft,
  rematchAsk,
  rematchWaiting,
  rematchWaitingHostStart,
  rematchGone,
}

String _variantLabel(_Variant v) {
  switch (v) {
    case _Variant.win:
      return 'win';
    case _Variant.lose:
      return 'lose';
    case _Variant.ended:
      return 'ended';
    case _Variant.friendLeft:
      return 'friend_left';
    case _Variant.everyoneLeft:
      return 'everyone_left';
    case _Variant.offline:
      return 'offline';
    case _Variant.offlineFriendLeft:
      return 'offline_friend_left';
    case _Variant.rematchAsk:
      return 'rematch_ask';
    case _Variant.rematchWaiting:
      return 'rematch_waiting';
    case _Variant.rematchWaitingHostStart:
      return 'rematch_waiting_host_start';
    case _Variant.rematchGone:
      return 'rematch_gone';
  }
}

/// The identity table from this file's own header note and the order's own
/// per-variant description: the keys that must be present, and (by
/// difference against [_allIdentityKeys]) the keys that must be absent.
List<Key> _presentKeys(_Variant v) {
  switch (v) {
    case _Variant.win:
      return <Key>[_winKey, _rematchKey];
    case _Variant.lose:
      return <Key>[_loseKey, _rematchKey];
    case _Variant.ended:
      return <Key>[_endedKey, _rematchKey];
    case _Variant.friendLeft:
      return <Key>[_loseKey, _leftKey, _rematchKey];
    case _Variant.everyoneLeft:
      return <Key>[_loseKey, _leftKey];
    case _Variant.offline:
      return <Key>[_loseKey, _offlineKey, _rematchKey];
    case _Variant.offlineFriendLeft:
      return <Key>[_loseKey, _leftKey, _offlineKey, _rematchKey];
    case _Variant.rematchAsk:
      return <Key>[_loseKey, _rematchAskKey, _rematchKey];
    case _Variant.rematchWaiting:
      return <Key>[_loseKey, _rematchWaitingKey];
    case _Variant.rematchWaitingHostStart:
      return <Key>[_winKey, _rematchWaitingKey, _rematchStartKey];
    case _Variant.rematchGone:
      return <Key>[_loseKey, _rematchGoneKey];
  }
}

/// Extra positive keys the order calls out by name but that are not part of
/// the mutual-exclusion pool in [_allIdentityKeys] (every variant renders
/// `game-screen-new-room-button` somewhere; only these two are named by the
/// order as "New table primary").
List<Key> _extraPresentKeys(_Variant v) {
  switch (v) {
    case _Variant.everyoneLeft:
    case _Variant.rematchGone:
      return <Key>[_newRoomKey];
    default:
      return const <Key>[];
  }
}

bool _triggersCelebration(_Variant v) =>
    v == _Variant.win || v == _Variant.rematchWaitingHostStart;

void _assertIdentity(
  WidgetTester tester, {
  required _Variant v,
  required String where,
}) {
  final List<Key> present = _presentKeys(v);
  for (final Key key in present) {
    expect(
      find.byKey(key),
      findsOneWidget,
      reason: '$where: identity for ${_variantLabel(v)} requires $key present.',
    );
  }
  for (final Key key in _extraPresentKeys(v)) {
    expect(
      find.byKey(key),
      findsOneWidget,
      reason: '$where: identity for ${_variantLabel(v)} requires $key present.',
    );
  }
  for (final Key key in _allIdentityKeys) {
    if (present.contains(key)) {
      continue;
    }
    expect(
      find.byKey(key),
      findsNothing,
      reason:
          '$where: identity for ${_variantLabel(v)} requires $key absent '
          '(it belongs to a different variant, so a green here would not '
          'prove ${_variantLabel(v)} was ever reached).',
    );
  }
  // Never any of our variants: FINISHED is never drawn as the dimmed stale
  // table (docs/PROTOCOL.md section 18 rule 4 / leave_table_end_card_test
  // .dart rule 4's own assertion).
  expect(
    find.byKey(_staleTableKey),
    findsNothing,
    reason:
        '$where: identity for ${_variantLabel(v)} requires game-screen-stale-table absent.',
  );
}

// --- frame helpers, copied by hand from the sibling suites' own idiom ------

const String _testUrl = 'wss://end-verify-probe.invalid/ws';
const String _roomCode = 'EVPROBE';

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'end-verify-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;
String _typeOf(String sentText) => _decode(sentText)['t']! as String;

String _frame({
  required String type,
  String? re,
  Map<String, Object?> data = const <String, Object?>{},
  String? id,
}) => jsonEncode(<String, Object?>{
  'v': 1,
  't': type,
  'id': id ?? _nextServerId(),
  're': ?re,
  'd': data,
});

Map<String, Object?> _seatJson(
  int seat, {
  required String name,
  List<int> tokens = const <int>[-1, -1, -1, -1],
}) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': true,
  'tokens': tokens,
  'client_seed': null,
  'seed_origin': null,
};

Map<String, Object?> _resetSeat(Map<String, Object?> seat) => <String, Object?>{
  ...seat,
  'tokens': const <int>[-1, -1, -1, -1],
};

List<Map<String, Object?>> _twoSeats() => <Map<String, Object?>>[
  _seatJson(0, name: 'Sam'),
  _seatJson(1, name: 'Bob'),
];

List<Map<String, Object?>> _threeSeats() => <Map<String, Object?>>[
  _seatJson(0, name: 'Sam'),
  _seatJson(1, name: 'Bob'),
  _seatJson(2, name: 'Ken'),
];

Map<String, Object?> _playingTurnJson() => <String, Object?>{
  'seat': 0,
  'phase': 'await_roll',
  'deadline_ms': 45000,
  'k': 0,
};

Map<String, Object?> _finishedTurnJson() => <String, Object?>{
  'seat': 0,
  'phase': 'finished',
  'deadline_ms': 0,
  'k': 1,
};

Map<String, Object?> _roomJson({
  required String state,
  required int hostSeat,
  required int players,
  required List<Map<String, Object?>> seats,
  Map<String, Object?>? turn,
  int? winner,
  String? gameId,
  String? clientSeeds,
  String? verifyUrl,
  Map<String, Object?>? rematch,
  int chainIndex = 0,
  required int seq,
}) => <String, Object?>{
  'code': _roomCode,
  'state': state,
  'host_seat': hostSeat,
  'players': players,
  'rules': <String, Object?>{
    'blocks': true,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': (chainIndex.isEven ? 'a' : 'b') * 64,
  'chain_index': chainIndex,
  'game_id': gameId,
  'client_seeds': clientSeeds,
  'seats': seats,
  'turn': turn,
  'winner': winner,
  'verify_url': ?verifyUrl,
  'rematch': ?rematch,
  'seq': seq,
};

String _verifyUrlFor(String gameId) =>
    'https://end-verify-probe.invalid/v/$gameId';

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];
  void enqueue(FakeTransport transport) => _queue.add(transport);
  Future<WireTransport> call(Uri url) async {
    if (_queue.isEmpty) {
      throw StateError(
        '_Connector: connect() has no transport queued for $url',
      );
    }
    return _queue.removeAt(0);
  }
}

// --- widget harness, copied by hand from test/next_step_in_view_end_test
// --- .dart's own _app/_mountGame/_loadAppFonts/_surface --------------------

// `disableAnimations` wraps `home` in the same `MaterialApp.builder` +
// `MediaQuery(...).copyWith(disableAnimations: true)` idiom
// test/home_motion_test.dart's own `_harness` uses, copied by hand (see
// this file's header note 5): this file imports nothing from another test
// file except test/net/fake_transport.dart.
Widget _app({
  required Locale locale,
  required Widget home,
  bool disableAnimations = false,
}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildAppTheme(),
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    builder: !disableAnimations
        ? null
        : (BuildContext context, Widget? child) {
            final MediaQueryData data = MediaQuery.of(context);
            return MediaQuery(
              data: data.copyWith(disableAnimations: true),
              child: child!,
            );
          },
    home: home,
  );
}

Future<void> _mountGame(
  WidgetTester tester, {
  required RoomController controller,
  required Locale locale,
  bool disableAnimations = false,
}) async {
  final FeedbackSettings settings = FeedbackSettings.forTest();
  addTearDown(settings.dispose);
  await tester.pumpWidget(
    _app(
      locale: locale,
      disableAnimations: disableAnimations,
      home: FeedbackScope(
        settings: settings,
        service: const NoopFeedbackService(),
        child: GameScreen(controller: controller),
      ),
    ),
  );
  await tester.pump();
}

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

  final FontLoader notoSansArabic = FontLoader('Noto Sans Arabic');
  for (final String asset in const <String>[
    'fonts/NotoSansArabic-Regular.ttf',
    'fonts/NotoSansArabic-Bold.ttf',
  ]) {
    notoSansArabic.addFont(rootBundle.load(asset));
  }
  await notoSansArabic.load();
}

Future<void> _surface(
  WidgetTester tester,
  _Shape shape,
  double scale,
  Future<void> Function() body,
) async {
  tester.view.physicalSize = shape.physical;
  tester.view.devicePixelRatio = shape.dpr;
  final FakeViewPadding inset = FakeViewPadding(
    top: shape.topInset * shape.dpr,
    bottom: shape.bottomInset * shape.dpr,
  );
  tester.view.padding = inset;
  tester.view.viewPadding = inset;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  addTearDown(tester.view.reset);
  try {
    await body();
  } finally {
    try {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    } finally {
      tester.view.reset();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    }
  }
}

// --- visibility / hit-test primitives, copied by hand from
// --- test/next_step_in_view_end_test.dart's own helpers ---------------------

String _scaleLabel(double scale) => scale.toStringAsFixed(1);

String _where(
  _Variant v,
  _Shape shape,
  double scale,
  Locale locale, {
  bool disableAnimations = false,
}) =>
    '${_variantLabel(v)}, ${shape.id}, scale ${_scaleLabel(scale)}, '
    '${locale.languageCode}${disableAnimations ? ', reduced-motion' : ''}';

String _box(Rect rect) =>
    '${rect.left.toStringAsFixed(1)},${rect.top.toStringAsFixed(1)} '
    '${rect.right.toStringAsFixed(1)},${rect.bottom.toStringAsFixed(1)}';

String _safe(_Shape shape) =>
    '0,${shape.topInset.toStringAsFixed(0)} '
    '${shape.width.toStringAsFixed(0)},${shape.safeBottom.toStringAsFixed(0)}';

bool _whollyInside(Rect rect, _Shape shape) {
  return rect.left >= -_fitSlop &&
      rect.top >= shape.topInset - _fitSlop &&
      rect.right <= shape.width + _fitSlop &&
      rect.bottom <= shape.safeBottom + _fitSlop;
}

ScrollableState? _scrollableAncestor(Element element) {
  ScrollableState? found;
  element.visitAncestorElements((Element ancestor) {
    if (ancestor.widget is Scrollable && ancestor is StatefulElement) {
      final State<StatefulWidget> state = ancestor.state;
      if (state is ScrollableState) {
        found = state;
        return false;
      }
    }
    return true;
  });
  return found;
}

Rect? _renderRect(RenderObject? object) {
  if (object is! RenderBox || !object.hasSize || !object.attached) {
    return null;
  }
  final Offset topLeft = object.localToGlobal(Offset.zero);
  final Offset bottomRight = object.localToGlobal(
    object.size.bottomRight(Offset.zero),
  );
  return Rect.fromPoints(topLeft, bottomRight);
}

bool _whollyInsideRect(Rect rect, Rect outer) {
  return rect.left >= outer.left - _fitSlop &&
      rect.top >= outer.top - _fitSlop &&
      rect.right <= outer.right + _fitSlop &&
      rect.bottom <= outer.bottom + _fitSlop;
}

const double _celebrationSlop = 0.5;
const double _celebrationCentreSlop = 1.0;
const double _celebrationDiameter = 196;

/// C-429 D4: `end-card-celebration` is present, its painted child (the
/// `CustomPaint` the animated burst builds, or the `Container` the
/// reduced-motion branch builds instead -- read live off
/// `MediaQuery.disableAnimationsOf`, not off a flag this file passed in, so
/// a mutation that picks the wrong branch for the current MediaQuery is
/// still caught) measures 196 x 196 within 0.5, and that child's own centre
/// sits within 1 px of `game-screen-winner`'s own centre.
void _assertCelebrationGeometry(WidgetTester tester, {required String where}) {
  final Finder celebration = find.byKey(_celebrationKey);
  expect(
    celebration,
    findsOneWidget,
    reason: '$where: end-card-celebration must be present on the win card.',
  );
  final bool reducedMotion = MediaQuery.disableAnimationsOf(
    tester.element(celebration),
  );
  final Type wantType = reducedMotion ? Container : CustomPaint;
  final Finder painted = find.descendant(
    of: celebration,
    matching: find.byType(wantType),
  );
  final int paintedCount = painted.evaluate().length;
  expect(
    paintedCount,
    1,
    reason:
        '$where: end-card-celebration must have exactly one $wantType '
        'descendant (the ${reducedMotion ? 'reduced-motion glow' : 'animated burst'}); '
        'found $paintedCount.',
  );
  final Size size = tester.getSize(painted);
  final bool sizeOk =
      (size.width - _celebrationDiameter).abs() <= _celebrationSlop &&
      (size.height - _celebrationDiameter).abs() <= _celebrationSlop;
  expect(
    sizeOk,
    isTrue,
    reason:
        '$where: celebration painted size '
        '${size.width.toStringAsFixed(1)}x${size.height.toStringAsFixed(1)} '
        'must be 196x196 within 0.5.',
  );
  final Offset paintedCentre = tester.getCenter(painted);
  final Offset titleCentre = tester.getCenter(find.byKey(_winnerTitleKey));
  final double dx = (paintedCentre.dx - titleCentre.dx).abs();
  final double dy = (paintedCentre.dy - titleCentre.dy).abs();
  final bool centreOk =
      dx <= _celebrationCentreSlop && dy <= _celebrationCentreSlop;
  expect(
    centreOk,
    isTrue,
    reason:
        '$where: celebration centre '
        '${paintedCentre.dx.toStringAsFixed(1)},${paintedCentre.dy.toStringAsFixed(1)} '
        'must be within 1px of game-screen-winner centre '
        '${titleCentre.dx.toStringAsFixed(1)},${titleCentre.dy.toStringAsFixed(1)} '
        '(dx=${dx.toStringAsFixed(2)} dy=${dy.toStringAsFixed(2)}).',
  );
}

bool _pathReaches(HitTestResult hits, RenderObject own) {
  for (final HitTestEntry<HitTestTarget> entry in hits.path) {
    final HitTestTarget target = entry.target;
    if (target == own) {
      return true;
    }
    if (target is RenderObject) {
      RenderObject? current = target.parent;
      while (current != null) {
        if (current == own) {
          return true;
        }
        current = current.parent;
      }
    }
  }
  return false;
}

String _hitClause(HitTestResult hits, Offset centre) {
  final String at =
      '${centre.dx.toStringAsFixed(1)},${centre.dy.toStringAsFixed(1)}';
  for (final HitTestEntry<HitTestTarget> entry in hits.path) {
    final HitTestTarget target = entry.target;
    if (target is RenderObject) {
      final Rect? hitRect = _renderRect(target);
      if (hitRect != null) {
        return '(c) centre $at hit ${_box(hitRect)}';
      }
    }
  }
  return '(c) centre $at hit nothing';
}

String _firstError(FlutterErrorDetails details) {
  String line = details.exceptionAsString().split('\n').first.trim();
  line = line.replaceAll(RegExp(r'\s+'), ' ');
  if (line.length > 140) {
    line = line.substring(0, 140);
  }
  return line;
}

/// One check's outcome: wholly inside the safe area (a), wholly inside the
/// Scrollable ancestor's own render box when there is one (b), and,
/// when [includeHitTest] is true, a hit test at the rect's centre reaches
/// this widget's render object or a descendant (c). Goal items 2 and 3
/// (the fairness line text, end-card-fair-hint) ask only for (a) and (b);
/// goal item 1 (the verify button) asks for all three -- see this file's
/// header note 1.
class _CheckResult {
  const _CheckResult({
    required this.ok,
    this.rect,
    this.viewport,
    this.problem,
  });
  final bool ok;
  final Rect? rect;
  final Rect? viewport;
  final String? problem;
}

_CheckResult _check(
  WidgetTester tester, {
  required Finder finder,
  required String name,
  required _Shape shape,
  required String where,
  bool includeHitTest = false,
}) {
  final int count = finder.evaluate().length;
  if (count != 1) {
    return _CheckResult(
      ok: false,
      problem:
          '$where: $name was found $count times, not once, so it is not on screen.',
    );
  }
  final Element element = finder.evaluate().single;
  final Rect rect = tester.getRect(finder);
  final List<String> failed = <String>[];
  if (!_whollyInside(rect, shape)) {
    failed.add('(a) outside safe rect ${_safe(shape)}');
  }
  Rect? viewport;
  final ScrollableState? scrollable = _scrollableAncestor(element);
  if (scrollable != null) {
    viewport = _renderRect(scrollable.context.findRenderObject());
    if (viewport == null) {
      failed.add('(b) scroll ancestor has no render box');
    } else if (!_whollyInsideRect(rect, viewport)) {
      failed.add('(b) outside scroll viewport ${_box(viewport)}');
    }
  }
  if (includeHitTest) {
    final RenderObject? own = element.renderObject;
    final Offset centre = rect.center;
    final HitTestResult hits = tester.hitTestOnBinding(centre);
    if (own == null || !_pathReaches(hits, own)) {
      failed.add(_hitClause(hits, centre));
    }
  }
  if (failed.isEmpty) {
    return _CheckResult(ok: true, rect: rect, viewport: viewport);
  }
  return _CheckResult(
    ok: false,
    rect: rect,
    viewport: viewport,
    problem: '$where: $name rect ${_box(rect)} failed ${failed.join('; ')}.',
  );
}

String _flag(bool ok) => ok ? 'GREEN' : 'RED';

String _px(double? value) =>
    value == null || value.isNaN ? 'n/a' : value.toStringAsFixed(1);

void _emit({
  required _Variant v,
  required _Shape shape,
  required double scale,
  required Locale locale,
  required bool reportOnly,
  required _CheckResult verify,
  required _CheckResult line,
  required _CheckResult hint,
  required int errCount,
}) {
  // header note 2: the dock's own top edge is the scroll viewport's own
  // bottom edge, by EndCardFrame.build's Column (Expanded(scroll) then the
  // dock, flush, nothing between).
  final double? dockTop = verify.viewport?.bottom;
  stdout.writeln(
    'ENDVERIFY state=${_variantLabel(v)} shape=${shape.id} '
    'scale=${_scaleLabel(scale)} locale=${locale.languageCode} '
    'verify=${_flag(verify.ok)} line=${_flag(line.ok)} hint=${_flag(hint.ok)} '
    'verifyBottom=${_px(verify.rect?.bottom)} '
    'viewportBottom=${_px(verify.viewport?.bottom)} '
    'dockTop=${_px(dockTop)} err=$errCount'
    '${reportOnly ? ' report-only' : ''}',
  );
}

// --- game_log settling ------------------------------------------------

/// Every case computes stats from an empty local transcript, which is
/// always incomplete, so `_gameOverBody` schedules exactly one `game_log`
/// request the first time the end card is up, connected, in FINISHED
/// (lib/src/game_screen.dart's own `_maybeFetchGameLog`). This answers it
/// with a structurally valid, empty reply so `_fetchGameLog`'s own
/// `frames.isEmpty` branch returns without touching layout, and no 10
/// second request timer is left pending at teardown. A transport already
/// closed needs nothing: RoomConnection fails every pending request with
/// ConnectionClosedException the moment the link goes, which is this same
/// cleanup by another path.
Future<void> _settleGameLog(
  WidgetTester tester,
  FakeTransport transport, {
  required String gameId,
}) async {
  await tester.pump();
  if (transport.isClosed) {
    return;
  }
  final List<String> logs = transport.sentRaw
      .where((String raw) => _typeOf(raw) == 'game_log')
      .toList();
  if (logs.isEmpty) {
    return;
  }
  final String reqId = _idOf(logs.single);
  transport.pushText(
    _frame(
      type: 'game_log',
      re: reqId,
      data: <String, Object?>{
        'game_id': gameId,
        'part': 1,
        'parts': 1,
        'frames': const <Object?>[],
      },
    ),
  );
  await tester.pump();
  await tester.pump();
}

// --- pushes shared by several variants ---------------------------------

Future<void> _pushPlayerLeft(
  WidgetTester tester,
  FakeTransport transport, {
  required int seat,
  required int seq,
}) async {
  transport.pushText(
    _frame(
      type: 'player_left',
      data: <String, Object?>{'seat': seat, 'seq': seq},
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> _pushLobbyRematch(
  WidgetTester tester,
  FakeTransport transport, {
  required int seq,
  required List<Map<String, Object?>> seats,
  required int by,
  required List<int> ready,
  required int hostSeat,
  required int players,
  required int chainIndex,
}) async {
  transport.pushText(
    _frame(
      type: 'room',
      data: _roomJson(
        state: 'LOBBY',
        hostSeat: hostSeat,
        players: players,
        seats: seats.map(_resetSeat).toList(),
        turn: null,
        winner: null,
        gameId: null,
        clientSeeds: null,
        chainIndex: chainIndex,
        rematch: <String, Object?>{'by': by, 'ready': ready},
        seq: seq,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

// --- reaching each variant through real frames --------------------------

/// Connects fresh into a live PLAYING room, mounts GameScreen, then pushes
/// an unsolicited `room` broadcast into FINISHED (so `lastFinished` is
/// recorded, per this file's own header note), settles the one `game_log`
/// request that follows, then runs [extra] for whatever the variant still
/// needs (a departure, a rematch LOBBY, a drop, a failed rematch).
Future<(RoomController, FakeTransport)> _reachViaBroadcast(
  WidgetTester tester, {
  required Locale locale,
  required List<Map<String, Object?>> seats,
  required int mySeat,
  required int winner,
  int hostSeat = 0,
  required String gameId,
  required Future<void> Function(WidgetTester, FakeTransport, RoomController)
  extra,
  bool disableAnimations = false,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );
  addTearDown(controller.dispose);

  final int players = seats.length;
  final String myName =
      seats.firstWhere((Map<String, Object?> s) => s['seat'] == mySeat)['name']!
          as String;

  final Future<void> future = controller.createRoom(
    name: myName,
    players: players,
  );
  await tester.runAsync(() => pumpEventQueue());
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
      data: _roomJson(
        state: 'PLAYING',
        hostSeat: hostSeat,
        players: players,
        seats: seats,
        turn: _playingTurnJson(),
        winner: null,
        seq: 1,
      ),
    ),
  );
  await future;

  await _mountGame(
    tester,
    controller: controller,
    locale: locale,
    disableAnimations: disableAnimations,
  );

  transport.pushText(
    _frame(
      type: 'room',
      data: _roomJson(
        state: 'FINISHED',
        hostSeat: hostSeat,
        players: players,
        seats: seats,
        turn: _finishedTurnJson(),
        winner: winner,
        verifyUrl: _verifyUrlFor(gameId),
        gameId: gameId,
        clientSeeds: '0:seed',
        seq: 2,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  await tester.pump();
  await _settleGameLog(tester, transport, gameId: gameId);

  await extra(tester, transport, controller);

  return (controller, transport);
}

/// `ended`: resumes straight into a FINISHED room whose own winner's seat
/// already left before this device ever connected (section 18 rule 3 frees
/// the seat entirely), so `winnerName` never resolves. See this file's
/// header note on why `end-card-ended` is reachable at all.
Future<(RoomController, FakeTransport)> _reachEnded(
  WidgetTester tester, {
  required Locale locale,
}) async {
  const String gameId = 'end-verify-probe-ended';
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );
  addTearDown(controller.dispose);

  final Future<void> future = controller.resumeRoom(
    code: _roomCode,
    seat: 1,
    seatToken: 'tok-resume-1',
  );
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  final String id = _idOf(transport.sentRaw.last);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': 1, 'seat_token': 'tok-resume-1'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: id,
      data: _roomJson(
        state: 'FINISHED',
        hostSeat: 0,
        players: 2,
        // The winner, seat 0, already left in FINISHED before this device
        // ever connected: section 18 rule 3 frees the seat entirely, so it
        // is simply absent, not merely disconnected.
        seats: <Map<String, Object?>>[_seatJson(1, name: 'Bob')],
        turn: _finishedTurnJson(),
        winner: 0,
        verifyUrl: _verifyUrlFor(gameId),
        gameId: gameId,
        clientSeeds: '0:seed',
        seq: 6,
      ),
    ),
  );
  await future;

  await _mountGame(tester, controller: controller, locale: locale);
  await _settleGameLog(tester, transport, gameId: gameId);

  return (controller, transport);
}

Future<void> _extraNone(
  WidgetTester tester,
  FakeTransport transport,
  RoomController controller,
) async {}

Future<void> _extraFriendLeft(
  WidgetTester tester,
  FakeTransport transport,
  RoomController controller,
) async {
  await _pushPlayerLeft(tester, transport, seat: 2, seq: 3);
}

Future<void> _extraEveryoneLeft(
  WidgetTester tester,
  FakeTransport transport,
  RoomController controller,
) async {
  await _pushPlayerLeft(tester, transport, seat: 0, seq: 3);
}

Future<void> _extraOffline(
  WidgetTester tester,
  FakeTransport transport,
  RoomController controller,
) async {
  transport.endFromFarSide();
  await tester.pump();
  await tester.pump();
}

Future<void> _extraOfflineFriendLeft(
  WidgetTester tester,
  FakeTransport transport,
  RoomController controller,
) async {
  await _pushPlayerLeft(tester, transport, seat: 2, seq: 3);
  transport.endFromFarSide();
  await tester.pump();
  await tester.pump();
}

Future<void> _extraRematchAsk(
  WidgetTester tester,
  FakeTransport transport,
  RoomController controller,
) async {
  await _pushLobbyRematch(
    tester,
    transport,
    seq: 3,
    seats: _twoSeats(),
    by: 0,
    ready: const <int>[0],
    hostSeat: 0,
    players: 2,
    chainIndex: 1,
  );
}

Future<void> _extraRematchWaiting(
  WidgetTester tester,
  FakeTransport transport,
  RoomController controller,
) async {
  await _pushLobbyRematch(
    tester,
    transport,
    seq: 3,
    seats: _twoSeats(),
    by: 1,
    ready: const <int>[1],
    hostSeat: 0,
    players: 2,
    chainIndex: 1,
  );
}

Future<void> _extraRematchWaitingHostStart(
  WidgetTester tester,
  FakeTransport transport,
  RoomController controller,
) async {
  await _pushLobbyRematch(
    tester,
    transport,
    seq: 3,
    seats: _threeSeats(),
    by: 0,
    ready: const <int>[0],
    hostSeat: 0,
    players: 3,
    chainIndex: 1,
  );
  await _pushLobbyRematch(
    tester,
    transport,
    seq: 4,
    seats: _threeSeats(),
    by: 0,
    ready: const <int>[0, 1],
    hostSeat: 0,
    players: 3,
    chainIndex: 1,
  );
}

Future<void> _extraRematchGone(
  WidgetTester tester,
  FakeTransport transport,
  RoomController controller,
) async {
  await tester.tap(find.byKey(_rematchKey));
  await tester.pump();
  final String reqId = _idOf(
    transport.sentRaw.where((String raw) => _typeOf(raw) == 'rematch').last,
  );
  transport.pushText(
    _frame(
      type: 'error',
      re: reqId,
      data: <String, Object?>{'code': 'NO_SUCH_ROOM', 'message': ''},
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<(RoomController, FakeTransport)> _reach(
  _Variant v,
  WidgetTester tester, {
  required Locale locale,
  bool disableAnimations = false,
}) {
  switch (v) {
    case _Variant.win:
      return _reachViaBroadcast(
        tester,
        locale: locale,
        seats: _twoSeats(),
        mySeat: 0,
        winner: 0,
        gameId: 'end-verify-probe-win',
        extra: _extraNone,
        disableAnimations: disableAnimations,
      );
    case _Variant.lose:
      return _reachViaBroadcast(
        tester,
        locale: locale,
        seats: _twoSeats(),
        mySeat: 1,
        winner: 0,
        gameId: 'end-verify-probe-lose',
        extra: _extraNone,
      );
    case _Variant.ended:
      return _reachEnded(tester, locale: locale);
    case _Variant.friendLeft:
      return _reachViaBroadcast(
        tester,
        locale: locale,
        seats: _threeSeats(),
        mySeat: 1,
        winner: 0,
        gameId: 'end-verify-probe-friend-left',
        extra: _extraFriendLeft,
      );
    case _Variant.everyoneLeft:
      return _reachViaBroadcast(
        tester,
        locale: locale,
        seats: _twoSeats(),
        mySeat: 1,
        winner: 0,
        gameId: 'end-verify-probe-everyone-left',
        extra: _extraEveryoneLeft,
      );
    case _Variant.offline:
      return _reachViaBroadcast(
        tester,
        locale: locale,
        seats: _twoSeats(),
        mySeat: 1,
        winner: 0,
        gameId: 'end-verify-probe-offline',
        extra: _extraOffline,
      );
    case _Variant.offlineFriendLeft:
      return _reachViaBroadcast(
        tester,
        locale: locale,
        seats: _threeSeats(),
        mySeat: 1,
        winner: 0,
        gameId: 'end-verify-probe-offline-friend-left',
        extra: _extraOfflineFriendLeft,
      );
    case _Variant.rematchAsk:
      return _reachViaBroadcast(
        tester,
        locale: locale,
        seats: _twoSeats(),
        mySeat: 1,
        winner: 0,
        gameId: 'end-verify-probe-rematch-ask',
        extra: _extraRematchAsk,
      );
    case _Variant.rematchWaiting:
      return _reachViaBroadcast(
        tester,
        locale: locale,
        seats: _twoSeats(),
        mySeat: 1,
        winner: 0,
        gameId: 'end-verify-probe-rematch-waiting',
        extra: _extraRematchWaiting,
      );
    case _Variant.rematchWaitingHostStart:
      return _reachViaBroadcast(
        tester,
        locale: locale,
        seats: _threeSeats(),
        mySeat: 0,
        winner: 0,
        gameId: 'end-verify-probe-rematch-waiting-host-start',
        extra: _extraRematchWaitingHostStart,
      );
    case _Variant.rematchGone:
      return _reachViaBroadcast(
        tester,
        locale: locale,
        seats: _twoSeats(),
        mySeat: 1,
        winner: 0,
        gameId: 'end-verify-probe-rematch-gone',
        extra: _extraRematchGone,
      );
  }
}

// --- the driver shared by every case -------------------------------------

Future<void> _runCase(
  WidgetTester tester, {
  required _Variant v,
  required _Shape shape,
  required double scale,
  required Locale locale,
  required bool reportOnly,
  bool checkCelebration = false,
  bool disableAnimations = false,
}) async {
  final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
  final FlutterExceptionHandler? previous = FlutterError.onError;
  FlutterError.onError = errors.add;
  try {
    await _surface(tester, shape, scale, () async {
      final String where = _where(
        v,
        shape,
        scale,
        locale,
        disableAnimations: disableAnimations,
      );
      final (RoomController _, FakeTransport _) = await _reach(
        v,
        tester,
        locale: locale,
        disableAnimations: disableAnimations,
      );

      if (_triggersCelebration(v)) {
        // Rule: no pumpAndSettle against a celebration. A bounded pump past
        // its own 1200ms burst (end_card.dart's _Celebration), matching
        // test/next_step_in_view_end_test.dart's own idiom, before this
        // case measures anything.
        for (int i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 200));
        }
      }

      _assertIdentity(tester, v: v, where: where);

      if (checkCelebration) {
        // C-429 D4, measured after the same bounded celebration pumps
        // above, same as every other check this case runs.
        _assertCelebrationGeometry(tester, where: where);
      }

      final AppLocalizations loc = AppLocalizations.of(
        tester.element(find.byType(GameScreen)),
      );

      final _CheckResult verify = _check(
        tester,
        finder: find.byKey(_verifyKey),
        name: 'game-screen-verify-button',
        shape: shape,
        where: where,
        includeHitTest: true,
      );
      final _CheckResult line = _check(
        tester,
        finder: find.text(loc.endFairLine),
        name: 'endFairLine text',
        shape: shape,
        where: where,
      );
      final _CheckResult hint = _check(
        tester,
        finder: find.byKey(_fairHintKey),
        name: 'end-card-fair-hint',
        shape: shape,
        where: where,
      );

      _emit(
        v: v,
        shape: shape,
        scale: scale,
        locale: locale,
        reportOnly: reportOnly,
        verify: verify,
        line: line,
        hint: hint,
        errCount: errors.length,
      );
      for (final FlutterErrorDetails details in errors) {
        stdout.writeln('ENDVERIFY-ERROR $where: ${_firstError(details)}');
      }

      if (!reportOnly) {
        expect(
          verify.ok,
          isTrue,
          reason: verify.problem ?? '$where: verify button check failed.',
        );
        expect(
          line.ok,
          isTrue,
          reason: line.problem ?? '$where: fairness line check failed.',
        );
        expect(
          hint.ok,
          isTrue,
          reason: hint.problem ?? '$where: fair-hint check failed.',
        );
        expect(
          errors,
          isEmpty,
          reason:
              '$where: layout reported ${errors.length} FlutterError(s), first '
              '"${errors.isEmpty ? '' : _firstError(errors.first)}".',
        );
      }
    });
  } finally {
    FlutterError.onError = previous;
  }
}

/// The variants asserted on s2 at scale 1.3: C-429 D3's `win` and `lose`,
/// then C-436 D3's friend_left, everyone_left, offline, rematch_gone and
/// rematch_ask. offline_friend_left is deliberately absent (C-436 D4).
const List<_Variant> _assertedAtLargeText = <_Variant>[
  _Variant.win,
  _Variant.lose,
  _Variant.friendLeft,
  _Variant.everyoneLeft,
  _Variant.offline,
  _Variant.rematchGone,
  _Variant.rematchAsk,
];

void main() {
  setUpAll(() async {
    await _loadAppFonts();
  });

  // Verdict matrix: s1/s2/s3 x en/ar x every variant, scale 1.0. C-429 D4
  // rides along on `win` at s2: checkCelebration is true only there.
  for (final _Shape shape in _shapes) {
    for (final Locale locale in _locales) {
      for (final _Variant v in _Variant.values) {
        final bool checkCelebration = shape == _s2 && v == _Variant.win;
        testWidgets(
          '${_variantLabel(v)} ${shape.id} 1.0 ${locale.languageCode}',
          (WidgetTester tester) async {
            await _runCase(
              tester,
              v: v,
              shape: shape,
              scale: 1.0,
              locale: locale,
              reportOnly: false,
              checkCelebration: checkCelebration,
            );
          },
        );
      }
    }
  }

  // C-429 D4's one extra reduced-motion mount: `win`, s2, scale 1.0,
  // `MediaQuery.disableAnimations` true. Locale `en` -- see this file's
  // header note 5 on why no second locale is mounted here.
  testWidgets('${_variantLabel(_Variant.win)} s2 1.0 en reduced-motion', (
    WidgetTester tester,
  ) async {
    await _runCase(
      tester,
      v: _Variant.win,
      shape: _s2,
      scale: 1.0,
      locale: const Locale('en'),
      reportOnly: false,
      checkCelebration: true,
      disableAnimations: true,
    );
  });

  // C-429 D3 and C-436 D3: on s2 at scale 1.3, these variants, en and ar,
  // are in the verdict set and asserted. Every other variant at s2 1.3 is
  // report-only (below).
  for (final Locale locale in _locales) {
    for (final _Variant v in _assertedAtLargeText) {
      testWidgets('${_variantLabel(v)} s2 1.3 ${locale.languageCode}', (
        WidgetTester tester,
      ) async {
        await _runCase(
          tester,
          v: v,
          shape: _s2,
          scale: 1.3,
          locale: locale,
          reportOnly: false,
        );
      });
    }
  }

  // Report-only: s2 only, scale 1.3, en/ar, every variant not in
  // [_assertedAtLargeText]. That includes C-436 D4's stated limit,
  // offline_friend_left. Printed but never asserted (order's own "make them
  // pass whatever they measure").
  for (final Locale locale in _locales) {
    for (final _Variant v in _Variant.values) {
      if (_assertedAtLargeText.contains(v)) {
        continue;
      }
      testWidgets(
        '${_variantLabel(v)} s2 1.3 ${locale.languageCode} report-only',
        (WidgetTester tester) async {
          await _runCase(
            tester,
            v: v,
            shape: _s2,
            scale: 1.3,
            locale: locale,
            reportOnly: true,
          );
        },
      );
    }
  }
}
