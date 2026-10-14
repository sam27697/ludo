// Acceptance test for contract C-340 (work/ludo/orders/C-340-lobby-pills.md),
// written from that contract's six numbered rules and work order 341's own
// "What to assert" checklist, against no implementation of order 340's
// changes to lib/src/lobby_screen.dart: on this branch lobby-copy-link-button
// and lobby-copy-code-button are still bare TextButtons with no icon, no
// border and no shape override, and lobby-resync-button is still a bare
// TextButton inside the desync strip. Order 340 is a separate hand, writing
// lib/src/lobby_screen.dart in parallel from the same contract; neither order
// touches the other's files. Most cases below are therefore expected to
// read RED here, and that red is the expected result, not a mistake in this
// file.
//
// LobbyScreen is driven exactly the way test/lobby_screen_test.dart and
// test/lobby_action_theme_test.dart already drive it: a real RoomController
// over a FakeTransport (test/net/fake_transport.dart, read-only, not edited
// here), with the small connector double and JSON/frame helpers copied from
// those files' own idiom rather than imported -- neither file exports them,
// and this order's file list does not permit editing either file. The
// desync strip (and lobby-resync-button inside it) is reached the same way
// test/lobby_screen_test.dart's "rule 5: desync banner is additive" group
// reaches it near its own line 718: push a `presence` delta whose `seq`
// does not follow the room's last seq, which sets `controller.hasDesynced`
// without moving `phase` off `connected`.
//
// A widget's resolved [ButtonStyle] is read the way
// flutter/src/material/button_style_button.dart's own `_ButtonStyleState.
// build` computes it: the widget's own `style`, then its component theme's
// style (`themeStyleOf`), then `defaultStyleOf`, each `WidgetStateProperty`
// resolved at the given state set in that order, first non-null wins. A
// class check alone (`widget is TextButton`) would pass on a TextButton
// restyled into a caption, so every pill assertion below reads the resolved
// style and the rendered tree instead.
//
// Ambiguities found while writing this file, reported rather than invented
// around (standing rule: "Ambiguity is reported, never invented around"):
//
//   1. `ButtonStyleButton.themeStyleOf` and `.defaultStyleOf` carry
//      `@protected` on their *abstract* declaration in button_style_button.
//      dart, but Flutter's own concrete overrides (OutlinedButton,
//      TextButton, ElevatedButton) do not repeat that annotation, so the
//      analyzer only flags `invalid_use_of_protected_member` when the call
//      site's static type is the abstract `ButtonStyleButton` itself, not
//      when it is one of those concrete subclasses. `_resolveEnabledStyle`
//      below therefore type-tests the widget into one of exactly those
//      three concrete types before calling either method, and fails loudly
//      (naming the unexpected runtimeType) for anything else, rather than
//      casting to the abstract class the way a quick reading of the work
//      order's parenthetical might suggest -- that cast compiles but trips
//      `flutter analyze`, which this order requires to read 0 issues.
//   2. The states resolved against are the empty set (`<WidgetState>{}`):
//      enabled, unhovered, unpressed, unfocused -- "resolved for the enabled
//      state" read literally as the button's resting look, not any
//      interaction state.
//   3. Contract rule 3 asks the resync pill's border and label to sit in
//      the desync strip's `onErrorContainer` colour specifically. Order
//      341's own "What to assert" checklist (its numbered items 1-7) is the
//      authority for what this file proves, and its item 1 asks only for
//      "colour alpha > 0" on the border, not a match to that exact hue; this
//      file follows the order's checklist and does not add a separate
//      onErrorContainer colour-match assertion beyond what the order lists.
//   4. Item 4 (rule 2's background/ordering case) is wholly green on this
//      tree, before order 340 lands, because none of its four sub-checks
//      depend on that order: a bare `TextButton`'s own stock default
//      background is already transparent at every state (so both copy
//      pills already resolve alpha 0), `lobby-share-button` already sits
//      above the copy-button row in the existing source order, and
//      `lobby-share-button`'s filled `ElevatedButton` background is
//      untouched by this contract. This is a real regression guard -- a
//      future change that broke any of those four facts would be a real
//      bug -- not an invented assertion, and the standing rule is "a case
//      that is green here must be the rule 5 control or you must say why
//      it is green", which this note is doing for item 4.
//   5. Rule 6 (item 6) needed the real app fonts loaded (the same way
//      test/end_card_labels_fit_test.dart's own `_loadAppFonts` does):
//      without them, the widget-test harness's fallback test font gives
//      "Copy link" and "Copy code" different glyph metrics than Poppins
//      does, which measured a false two-line wrap at 360dp even on this
//      unmodified tree -- a result about the test font, not about
//      production. Loading the shipped fonts first makes the measurement
//      answer the real question -- and with the real fonts in place, item
//      6 also reads green on this unmodified tree: the bare, unconstrained
//      "Copy link"/"Copy code" labels (no icon, no extra padding yet) were
//      already well short of wrapping at 360dp. Per the same standing rule
//      as ambiguity 4, that is reported here rather than left unexplained;
//      it is still a real regression guard against order 340 cramming the
//      label once the icon and its padding are added.
//
// Each case below prints one line starting "CASE" with the numbers it
// measured, so a red assertion's failure message is paired with the actual
// measurement that produced it, and the exact scenario needed to reproduce
// it (this file has no randomness: every scenario is a fixed code, locale
// and seat layout named at the call site).

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://example.test/ws';
const String _testCode = 'ABC234';

const Key _copyLinkKey = Key('lobby-copy-link-button');
const Key _copyCodeKey = Key('lobby-copy-code-button');
const Key _resyncKey = Key('lobby-resync-button');
const Key _shareKey = Key('lobby-share-button');

/// Loads the shipped Poppins and Noto Sans Arabic fonts, the same assets
/// pubspec.yaml declares and the same way test/end_card_labels_fit_test.dart
/// already loads them, so rule 6's label-fit measurement reads real glyph
/// metrics instead of the widget-test harness's fallback test font
/// (ambiguity 5 above).
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

// --- server-side id generation for pushed frames ---------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'pills-srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

// --- small JSON helpers, mirroring test/lobby_screen_test.dart's own idiom -

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;

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

Map<String, Object?> _roomJson({
  String code = _testCode,
  String state = 'LOBBY',
  int hostSeat = 0,
  int players = 4,
  List<Map<String, Object?>>? seats,
  int seq = 1,
}) => <String, Object?>{
  'code': code,
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
  'seats':
      seats ??
      <Map<String, Object?>>[_seatJson(hostSeat, name: 'Sam', connected: true)],
  'turn': null,
  'winner': null,
  'seq': seq,
};

// --- a TransportConnector test double, copied from lobby_screen_test.dart's
// --- own idiom rather than imported: it is not exported by that file, and
// --- that file is not on this order's file list to modify. -----------------

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];
  final List<Uri> calls = <Uri>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    calls.add(url);
    if (_queue.isEmpty) {
      throw StateError(
        '_Connector: connect() call #${calls.length} has no transport '
        'queued; the test scenario is broken, not the code under test',
      );
    }
    return _queue.removeAt(0);
  }
}

RoomController _newController(_Connector connector) =>
    RoomController(serverUrl: Uri.parse(_testUrl), connect: connector.call);

// --- widget harness, themed the way lobby_action_theme_test.dart's own
// --- `_localizations` is, since this file's whole point is to measure
// --- theme-resolved button style. ------------------------------------------

Widget _harness(Widget child, {Locale locale = const Locale('en')}) {
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
    home: child,
  );
}

Future<String> _mountAndCaptureRequest(
  WidgetTester tester,
  Widget screen,
  FakeTransport transport, {
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(_harness(screen, locale: locale));
  await tester.pump();
  expect(
    transport.sentRaw,
    isNotEmpty,
    reason:
        'test setup: expected LobbyScreen.initState to have sent exactly '
        'one request to the transport by now (createRoom); sentRaw is '
        'empty',
  );
  return _idOf(transport.sentRaw.last);
}

Future<void> _resolveConnected(
  WidgetTester tester,
  FakeTransport transport,
  String requestId, {
  required int seatForThisClient,
  String code = _testCode,
  int players = 4,
  int hostSeat = 0,
  List<Map<String, Object?>>? seats,
  int seq = 1,
}) async {
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{
        'seat': seatForThisClient,
        'seat_token': 'tok-$seatForThisClient',
      },
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: requestId,
      data: _roomJson(
        code: code,
        players: players,
        hostSeat: hostSeat,
        seats: seats,
        seq: seq,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

/// What a single scenario mount hands back: the controller so a test can
/// dispose it, and the transport so a test can push a further frame (the
/// desync delta) into the same live connection.
class _LobbyHarness {
  const _LobbyHarness({required this.controller, required this.transport});
  final RoomController controller;
  final FakeTransport transport;
}

/// Mounts a connected, single-seat host lobby for [_testCode], in [locale].
/// The one seat (seat 0, "Sam") is also the host, so every action this file
/// measures (copy link, copy code, share, and -- once desynced -- resync)
/// is enabled on the mounted screen.
Future<_LobbyHarness> _mountConnectedHostLobby(
  WidgetTester tester, {
  Locale locale = const Locale('en'),
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = _newController(connector);

  final String id = await _mountAndCaptureRequest(
    tester,
    LobbyScreen(
      controller: controller,
      action: LobbyAction.create,
      playerName: 'Sam',
      players: 4,
    ),
    transport,
    locale: locale,
  );
  await _resolveConnected(
    tester,
    transport,
    id,
    seatForThisClient: 0,
    hostSeat: 0,
    players: 4,
    seats: <Map<String, Object?>>[_seatJson(0, name: 'Sam')],
  );
  expect(
    controller.phase,
    RoomPhase.connected,
    reason:
        'test setup: expected RoomPhase.connected for code $_testCode '
        'after the room reply; got ${controller.phase}',
  );
  return _LobbyHarness(controller: controller, transport: transport);
}

/// Sets `controller.hasDesynced` without moving `phase` off `connected`, the
/// same way test/lobby_screen_test.dart's "rule 5: desync banner is
/// additive" group does near its own line 718: a `presence` delta whose
/// `seq` does not follow the room's last seq (the mounted room above is
/// seq 1; this pushes seq 9). That is what makes `lobby-resync-button`
/// appear inside the desync strip on an otherwise ordinary connected lobby.
Future<void> _desync(
  WidgetTester tester,
  FakeTransport transport,
  RoomController controller,
) async {
  expect(
    controller.hasDesynced,
    isFalse,
    reason: 'test setup: the harness must start undesynced',
  );
  transport.pushText(
    _frame(
      type: 'presence',
      data: <String, Object?>{'seat': 0, 'connected': false, 'seq': 9},
    ),
  );
  await tester.pump();
  await tester.pump();
  expect(
    controller.hasDesynced,
    isTrue,
    reason:
        'test setup: a presence delta with seq 9 against a seq-1 room must '
        'set controller.hasDesynced (scenario: seq 9 pushed against room '
        'seq 1); it did not, so lobby-resync-button cannot be reached',
  );
}

// --- ButtonStyle resolution: widget style, then component theme, then
// --- defaultStyleOf, each resolved at the given states -- the same
// --- precedence flutter/src/material/button_style_button.dart's own
// --- _ButtonStyleState.build applies (see ambiguity 1 above for why this
// --- type-tests into a concrete subclass rather than casting to the
// --- abstract ButtonStyleButton). ------------------------------------------

ButtonStyle? _themeStyleOf(Widget widget, BuildContext context) {
  if (widget is OutlinedButton) {
    return widget.themeStyleOf(context);
  }
  if (widget is TextButton) {
    return widget.themeStyleOf(context);
  }
  if (widget is ElevatedButton) {
    return widget.themeStyleOf(context);
  }
  throw ArgumentError(
    '_themeStyleOf: unsupported button type ${widget.runtimeType}; this '
    'file only knows how to resolve OutlinedButton, TextButton and '
    'ElevatedButton styles',
  );
}

ButtonStyle _defaultStyleOf(Widget widget, BuildContext context) {
  if (widget is OutlinedButton) {
    return widget.defaultStyleOf(context);
  }
  if (widget is TextButton) {
    return widget.defaultStyleOf(context);
  }
  if (widget is ElevatedButton) {
    return widget.defaultStyleOf(context);
  }
  throw ArgumentError(
    '_defaultStyleOf: unsupported button type ${widget.runtimeType}; this '
    'file only knows how to resolve OutlinedButton, TextButton and '
    'ElevatedButton styles',
  );
}

ButtonStyle? _ownStyleOf(Widget widget) {
  if (widget is OutlinedButton) {
    return widget.style;
  }
  if (widget is TextButton) {
    return widget.style;
  }
  if (widget is ElevatedButton) {
    return widget.style;
  }
  throw ArgumentError(
    '_ownStyleOf: unsupported button type ${widget.runtimeType}; this file '
    'only knows how to resolve OutlinedButton, TextButton and '
    'ElevatedButton styles',
  );
}

/// What this file measures off a resolved [ButtonStyle]: enough to prove
/// contract rule 1 (side, shape) and rule 2 (backgroundColor), at the
/// enabled-and-at-rest state (ambiguity 2).
class _ResolvedButtonStyle {
  const _ResolvedButtonStyle({
    required this.side,
    required this.shape,
    required this.backgroundColor,
  });

  final BorderSide? side;
  final OutlinedBorder? shape;
  final Color? backgroundColor;
}

const Set<WidgetState> _enabledAtRest = <WidgetState>{};

_ResolvedButtonStyle _resolveEnabledStyle(WidgetTester tester, Finder finder) {
  final Widget widget = tester.widget(finder);
  final BuildContext context = tester.element(finder);
  final ButtonStyle? widgetStyle = _ownStyleOf(widget);
  final ButtonStyle? themeStyle = _themeStyleOf(widget, context);
  final ButtonStyle defaultStyle = _defaultStyleOf(widget, context);

  T? resolve<T>(WidgetStateProperty<T>? Function(ButtonStyle? style) pick) {
    return pick(widgetStyle)?.resolve(_enabledAtRest) ??
        pick(themeStyle)?.resolve(_enabledAtRest) ??
        pick(defaultStyle)?.resolve(_enabledAtRest);
  }

  return _ResolvedButtonStyle(
    side: resolve<BorderSide?>((ButtonStyle? style) => style?.side),
    shape: resolve<OutlinedBorder?>((ButtonStyle? style) => style?.shape),
    backgroundColor: resolve<Color?>(
      (ButtonStyle? style) => style?.backgroundColor,
    ),
  );
}

/// Contract rule 1: "a rounded shape (StadiumBorder or a
/// RoundedRectangleBorder with kRadiusControl)".
bool _isPillShape(OutlinedBorder? shape) {
  if (shape is StadiumBorder) {
    return true;
  }
  if (shape is RoundedRectangleBorder) {
    return shape.borderRadius == BorderRadius.circular(kRadiusControl);
  }
  return false;
}

String _labelFor(Key key, AppLocalizations loc) {
  if (key == _copyLinkKey) {
    return loc.lobbyCopyLinkButton;
  }
  if (key == _copyCodeKey) {
    return loc.lobbyCopyCodeButton;
  }
  if (key == _resyncKey) {
    return loc.lobbyResyncButton;
  }
  throw ArgumentError('_labelFor: no label mapping for $key');
}

/// The three pills contract C-340 restyles, each with the icon rule 1 or
/// rule 3 names for it.
const List<({Key key, IconData icon})> _pills = <({Key key, IconData icon})>[
  (key: _copyLinkKey, icon: Icons.link),
  (key: _copyCodeKey, icon: Icons.content_copy),
  (key: _resyncKey, icon: Icons.sync),
];

/// Mounts [pill]'s scenario (desyncing first when [pill] is the resync
/// button) and returns the harness, so every per-pill test starts from the
/// same reachable state.
Future<_LobbyHarness> _mountPillScenario(
  WidgetTester tester,
  Key pillKey, {
  Locale locale = const Locale('en'),
}) async {
  final _LobbyHarness harness = await _mountConnectedHostLobby(
    tester,
    locale: locale,
  );
  if (pillKey == _resyncKey) {
    await _desync(tester, harness.transport, harness.controller);
  }
  return harness;
}

/// Each case's one CASE line with its measured numbers (work order 341: "a
/// red reads as a measurement"), the same `// ignore: avoid_print` idiom
/// test/end_card_labels_fit_test.dart and test/large_text_fit_test.dart
/// already use, so `flutter analyze` reads 0 issues.
void _print(String line) {
  // ignore: avoid_print
  print(line);
}

void main() {
  setUpAll(_loadAppFonts);

  // --- Items 1-3: each pill is an outlined shape, carries its icon, is at
  // --- least 48 high. ------------------------------------------------------
  group('items 1-3: lobby-copy-link-button, lobby-copy-code-button and '
      'lobby-resync-button each resolve a visible border, a pill shape, '
      'carry their icon, and are at least 48 high', () {
    for (final pill in _pills) {
      testWidgets('${pill.key}', (tester) async {
        final _LobbyHarness harness = await _mountPillScenario(
          tester,
          pill.key,
        );
        addTearDown(harness.controller.dispose);

        final Finder finder = find.byKey(pill.key);
        expect(
          finder,
          findsOneWidget,
          reason:
              '${pill.key} must be present in the tree before its style '
              'can be measured; scenario code $_testCode',
        );

        final _ResolvedButtonStyle style = _resolveEnabledStyle(tester, finder);
        final Size size = tester.getSize(finder);
        final Finder iconFinder = find.descendant(
          of: finder,
          matching: find.byIcon(pill.icon),
        );

        _print(
          'CASE ${pill.key}: side=${style.side} shape=${style.shape} '
          'height=${size.height} icon=${pill.icon} '
          'iconDescendants=${iconFinder.evaluate().length}',
        );

        expect(
          style.side,
          isNotNull,
          reason:
              'rule 1: ${pill.key} resolved ButtonStyle.side must be '
              'non-null (a visible border); resolved side was null',
        );
        expect(
          style.side!.width,
          greaterThanOrEqualTo(1),
          reason:
              'rule 1: ${pill.key} border width must be >= 1; measured '
              '${style.side!.width}',
        );
        expect(
          style.side!.color.a,
          greaterThan(0),
          reason:
              'rule 1: ${pill.key} border colour alpha must be > 0; '
              'measured ${style.side!.color.a} (colour '
              '${style.side!.color})',
        );
        expect(
          _isPillShape(style.shape),
          isTrue,
          reason:
              'rule 1: ${pill.key} shape must be a StadiumBorder or a '
              'RoundedRectangleBorder with kRadiusControl '
              '($kRadiusControl); measured ${style.shape}',
        );

        expect(
          iconFinder,
          findsOneWidget,
          reason:
              'rule 1/3: ${pill.key} must contain exactly one '
              'Icon(${pill.icon}) descendant',
        );

        expect(
          size.height,
          greaterThanOrEqualTo(48),
          reason:
              'rule 1/3: ${pill.key} rendered height must be >= 48; '
              'measured ${size.height}',
        );
      });
    }
  });

  // --- Item 4: rule 2. Both copy pills are quieter than Invite friends. ---
  group('item 4: rule 2, both copy pills resolve a transparent background '
      'while lobby-share-button stays filled and above both', () {
    testWidgets('code $_testCode, en locale', (tester) async {
      final _LobbyHarness harness = await _mountConnectedHostLobby(tester);
      addTearDown(harness.controller.dispose);

      final Finder copyLinkFinder = find.byKey(_copyLinkKey);
      final Finder copyCodeFinder = find.byKey(_copyCodeKey);
      final Finder shareFinder = find.byKey(_shareKey);

      final double copyLinkAlpha =
          _resolveEnabledStyle(tester, copyLinkFinder).backgroundColor?.a ??
          0.0;
      final double copyCodeAlpha =
          _resolveEnabledStyle(tester, copyCodeFinder).backgroundColor?.a ??
          0.0;
      final double shareAlpha =
          _resolveEnabledStyle(tester, shareFinder).backgroundColor?.a ?? 0.0;

      final double shareTop = tester.getTopLeft(shareFinder).dy;
      final double copyLinkTop = tester.getTopLeft(copyLinkFinder).dy;
      final double copyCodeTop = tester.getTopLeft(copyCodeFinder).dy;

      _print(
        'CASE rule2-background: copyLinkAlpha=$copyLinkAlpha '
        'copyCodeAlpha=$copyCodeAlpha shareAlpha=$shareAlpha '
        'shareTop=$shareTop copyLinkTop=$copyLinkTop '
        'copyCodeTop=$copyCodeTop',
      );

      // Already true without order 340 (ambiguity 4): a bare TextButton's
      // stock background is transparent at every state.
      expect(
        copyLinkAlpha,
        0.0,
        reason:
            'rule 2: lobby-copy-link-button resolved background alpha '
            'must be 0; measured $copyLinkAlpha',
      );
      expect(
        copyCodeAlpha,
        0.0,
        reason:
            'rule 2: lobby-copy-code-button resolved background alpha '
            'must be 0; measured $copyCodeAlpha',
      );
      // Already true without order 340 (ambiguity 4): lobby-share-button
      // is untouched by this contract.
      expect(
        shareAlpha,
        greaterThan(0.0),
        reason:
            'rule 2: lobby-share-button must keep a filled (alpha > 0) '
            'background; measured $shareAlpha',
      );
      // Already true without order 340 (ambiguity 4): the share button
      // already sits above the copy-button row in the existing source.
      expect(
        shareTop,
        lessThan(copyLinkTop),
        reason:
            'rule 2: lobby-share-button must sit above '
            'lobby-copy-link-button; shareTop=$shareTop '
            'copyLinkTop=$copyLinkTop',
      );
      expect(
        shareTop,
        lessThan(copyCodeTop),
        reason:
            'rule 2: lobby-share-button must sit above '
            'lobby-copy-code-button; shareTop=$shareTop '
            'copyCodeTop=$copyCodeTop',
      );
    });
  });

  // --- Item 5: rule 4. The icon sits on the reading-start side, en and ar,
  // --- for every restyled pill. --------------------------------------------
  group('item 5: rule 4, each pill\'s icon sits on the reading-start side of '
      'its label', () {
    for (final pill in _pills) {
      for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
        testWidgets('${pill.key}, locale ${locale.languageCode}', (
          tester,
        ) async {
          final _LobbyHarness harness = await _mountPillScenario(
            tester,
            pill.key,
            locale: locale,
          );
          addTearDown(harness.controller.dispose);

          final Finder finder = find.byKey(pill.key);
          expect(
            finder,
            findsOneWidget,
            reason:
                '${pill.key} must be present before its icon/label '
                'positions can be measured, locale ${locale.languageCode}',
          );
          final AppLocalizations loc = AppLocalizations.of(
            tester.element(find.byType(LobbyScreen)),
          );
          final String label = _labelFor(pill.key, loc);

          final Finder iconFinder = find.descendant(
            of: finder,
            matching: find.byIcon(pill.icon),
          );
          final Finder labelFinder = find.descendant(
            of: finder,
            matching: find.text(label),
          );
          expect(
            iconFinder,
            findsOneWidget,
            reason:
                'rule 4: ${pill.key} must contain exactly one '
                'Icon(${pill.icon}) descendant to measure its position, '
                'locale ${locale.languageCode}',
          );
          expect(
            labelFinder,
            findsOneWidget,
            reason:
                'rule 4: ${pill.key} must contain exactly one '
                'Text("$label") descendant to measure its position, '
                'locale ${locale.languageCode}',
          );

          final double iconX = tester.getCenter(iconFinder).dx;
          final double labelX = tester.getCenter(labelFinder).dx;

          _print(
            'CASE rule4-mirror ${pill.key} ${locale.languageCode}: '
            'iconX=$iconX labelX=$labelX',
          );

          if (locale.languageCode == 'en') {
            expect(
              iconX,
              lessThan(labelX),
              reason:
                  'rule 4: en, ${pill.key}\'s icon centre x ($iconX) must '
                  'be less than its label centre x ($labelX)',
            );
          } else {
            expect(
              iconX,
              greaterThan(labelX),
              reason:
                  'rule 4: ar, ${pill.key}\'s icon centre x ($iconX) must '
                  'be greater than its label centre x ($labelX)',
            );
          }
        });
      }
    }
  });

  // --- Item 6: rule 6. Fits at 360x640, both locales, no wrap, no
  // --- ellipsis, for the two copy labels. ------------------------------
  group('item 6: rule 6, at 360x640 each copy label stays one line in both '
      'locales', () {
    for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
      testWidgets('locale ${locale.languageCode}', (tester) async {
        tester.view.physicalSize = const Size(360, 640);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final _LobbyHarness harness = await _mountConnectedHostLobby(
          tester,
          locale: locale,
        );
        addTearDown(harness.controller.dispose);

        final AppLocalizations loc = AppLocalizations.of(
          tester.element(find.byType(LobbyScreen)),
        );
        final TextDirection direction = locale.languageCode == 'ar'
            ? TextDirection.rtl
            : TextDirection.ltr;

        for (final (Key key, String label) in <(Key, String)>[
          (_copyLinkKey, loc.lobbyCopyLinkButton),
          (_copyCodeKey, loc.lobbyCopyCodeButton),
        ]) {
          final Finder buttonFinder = find.byKey(key);
          final Finder labelFinder = find.descendant(
            of: buttonFinder,
            matching: find.text(label),
          );
          expect(
            labelFinder,
            findsOneWidget,
            reason:
                'rule 6: $key must show exactly one Text("$label") label '
                'at 360x640, locale ${locale.languageCode}',
          );
          final Size labelSize = tester.getSize(labelFinder);
          final RenderParagraph paragraph = tester
              .renderObject<RenderParagraph>(
                find.descendant(
                  of: labelFinder,
                  matching: find.byType(RichText),
                ),
              );
          final TextStyle? style = paragraph.text.style;

          final TextPainter painter = TextPainter(
            text: TextSpan(text: label, style: style),
            maxLines: 1,
            textDirection: direction,
          )..layout(maxWidth: labelSize.width);

          _print(
            'CASE rule6 $key ${locale.languageCode}: '
            'labelWidth=${labelSize.width} labelHeight=${labelSize.height} '
            'didExceedMaxLines=${painter.didExceedMaxLines} '
            'painterHeight=${painter.height}',
          );

          expect(
            painter.didExceedMaxLines,
            isFalse,
            reason:
                'rule 6: $key label "$label" laid out at its own '
                'rendered width ${labelSize.width} with maxLines: 1 must '
                'not exceed one line, locale ${locale.languageCode}',
          );
          expect(
            labelSize.height,
            closeTo(painter.height, 1.0),
            reason:
                'rule 6: $key rendered height ${labelSize.height} must '
                'equal a single line\'s height ${painter.height}, not a '
                'wrapped two-line height, locale ${locale.languageCode}',
          );
        }
      });
    }
  });

  // --- Item 7: rule 5 control. Must stay green on both trees. -------------
  group('item 7: rule 5 control, tapping lobby-copy-link-button still puts '
      'kRoomLinkBase + code on the clipboard', () {
    testWidgets('code $_testCode, en locale', (tester) async {
      final List<String> clipboardCalls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          if (call.method == 'Clipboard.setData') {
            final Map<Object?, Object?> args =
                call.arguments as Map<Object?, Object?>;
            clipboardCalls.add(args['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      final _LobbyHarness harness = await _mountConnectedHostLobby(tester);
      addTearDown(harness.controller.dispose);

      await tester.tap(find.byKey(_copyLinkKey));
      await tester.pump();

      _print(
        'CASE rule5-control: clipboardCalls=$clipboardCalls '
        'expected=[${kRoomLinkBase + _testCode}]',
      );

      expect(
        clipboardCalls,
        <String>[kRoomLinkBase + _testCode],
        reason:
            'rule 5 control: tapping lobby-copy-link-button must still '
            'put kRoomLinkBase + code on the clipboard, unaffected by '
            'the pill restyle; scenario code $_testCode; got '
            '$clipboardCalls',
      );
    });
  });
}
