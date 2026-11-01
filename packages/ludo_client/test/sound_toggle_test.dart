// Proof for contract C-523 (work/ludo/orders/C-523-home-plain-and-one-sound-
// switch.md), rules D7 and D8: one sound switch, SoundToggleButton, in the
// three places the settings button stood (home, lobby, game), and
// FeedbackSettings.muted with its load() migration. Written from the
// contract text, against no implementation of it. On origin/main 7501227
// SoundToggleButton and FeedbackSettings.muted do not exist, the keys
// home-sound-toggle, lobby-sound-toggle and game-sound-toggle are not
// built, and the settings button is, so this file does not compile until
// the implementation lands; that is expected.
//
// Screens are driven the way lobby_settings_button_test.dart and
// feedback_settings_sheet_test.dart drive them: the screen is mounted
// directly in a MaterialApp under an explicit FeedbackScope, so a case holds
// the exact FeedbackSettings instance and a recording FeedbackService, and
// the lobby and game sit over a real RoomController on a FakeTransport
// (test/net/fake_transport.dart, read-only here). The harness is copied by
// hand from those two files, not imported. No pumpAndSettle once a lobby or
// a game is mounted (a live countdown never settles): bounded pumps only.
//
// The recording service also captures settings.muted at the instant a cue
// is played, which is how D7's "plays tap once after the flip" is told
// apart from a tap played before the flip.
//
// Ambiguities, reported rather than invented around:
//
//   1. D7 says "the settings button stood" in each of lobby and game but
//      does not list the lobby's stale state (a dropped socket with a room
//      held) or the game's finished state. Both are included, because the
//      settings button it replaces was pinned there (C-335, C-329); if the
//      contract meant otherwise those two rigs are the ones to drop.
//   2. D7 asks for the "frame style the settings button had" through the
//      `style` parameter and names no observable. The style case paints a
//      SoundToggleButton with an opaque background colour and looks for that
//      colour among the painted pixels of the control, which does not depend
//      on what widget the control is built from.

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meta/meta.dart' show isTest;
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/sound_toggle.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

const String _labelEn = 'Sound and vibration';
const String _labelAr = 'الصوت والاهتزاز';

const Size _surface = Size(390, 844);
const String _testUrl = 'wss://sound-toggle-test.invalid/ws';

const List<String> _removedKeys = <String>[
  'home-settings-button',
  'lobby-settings-button',
  'game-settings-button',
  'feedback-settings-sheet',
  'feedback-settings-haptics',
  'feedback-settings-sound',
];

// --- wire helpers, copied from the sibling suites' own idiom ----------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'snd-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

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

Map<String, Object?> _seatJson(int seat, {String name = ''}) =>
    <String, Object?>{
      'seat': seat,
      'name': name,
      'connected': true,
      'tokens': const <int>[-1, -1, -1, -1],
      'client_seed': null,
      'seed_origin': null,
    };

Map<String, Object?> _turnJson({
  required int seat,
  required String phase,
  required int deadlineMs,
  required int k,
}) => <String, Object?>{
  'seat': seat,
  'phase': phase,
  'deadline_ms': deadlineMs,
  'k': k,
};

Map<String, Object?> _roomJson({
  String state = 'LOBBY',
  int players = 2,
  Map<String, Object?>? turn,
  int? winner,
}) => <String, Object?>{
  'code': 'ABC234',
  'state': state,
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
  'seats': <Map<String, Object?>>[
    _seatJson(0, name: 'Host'),
    _seatJson(1, name: 'Guest'),
  ],
  'turn': turn,
  'winner': winner,
  'seq': 1,
};

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    if (_queue.isEmpty) {
      throw StateError('_Connector: no transport queued for $url');
    }
    return _queue.removeAt(0);
  }
}

/// Records every cue together with `settings.muted` as it stood when the
/// cue was played.
class _ProbeService implements FeedbackService {
  _ProbeService(this.settings);

  final FeedbackSettings settings;
  final List<FeedbackCue> cues = <FeedbackCue>[];
  final List<bool> mutedAtPlay = <bool>[];

  @override
  void play(FeedbackCue cue) {
    cues.add(cue);
    mutedAtPlay.add(settings.muted);
  }

  void clear() {
    cues.clear();
    mutedAtPlay.clear();
  }
}

// --- one mount function per screen -----------------------------------------

Widget _wrap({
  required Widget child,
  required FeedbackSettings settings,
  required FeedbackService service,
  required Locale locale,
}) {
  return MaterialApp(
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: FeedbackScope(settings: settings, service: service, child: child),
  );
}

typedef _Mount = Future<void> Function(
  WidgetTester tester,
  FeedbackSettings settings,
  FeedbackService service,
  Locale locale,
);

RoomController _newController(_Connector connector) =>
    RoomController(serverUrl: Uri.parse(_testUrl), connect: connector.call);

Future<void> _mountHome(
  WidgetTester tester,
  FeedbackSettings settings,
  FeedbackService service,
  Locale locale,
) async {
  await tester.pumpWidget(
    _wrap(
      child: HomeScreen(
        onToggleLocale: () {},
        controllerFactory: () => RoomController(
          serverUrl: Uri.parse(_testUrl),
          connect: (Uri url) async {
            throw StateError(
              'sound_toggle_test.dart: nothing here taps Create or Join',
            );
          },
        ),
      ),
      settings: settings,
      service: service,
      locale: locale,
    ),
  );
  await tester.pumpAndSettle();
}

Future<FakeTransport> _mountLobby(
  WidgetTester tester,
  FeedbackSettings settings,
  FeedbackService service,
  Locale locale, {
  required bool host,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = _newController(connector);
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    _wrap(
      child: LobbyScreen(
        controller: controller,
        action: host ? LobbyAction.create : LobbyAction.join,
        code: host ? null : 'ABC234',
        playerName: host ? 'Host' : 'Guest',
        players: 2,
      ),
      settings: settings,
      service: service,
      locale: locale,
    ),
  );
  await tester.pump();
  final String id = _idOf(transport.sentRaw.last);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{
        'seat': host ? 0 : 1,
        'seat_token': 'tok-${host ? 0 : 1}',
      },
    ),
  );
  transport.pushText(_frame(type: 'room', re: id, data: _roomJson()));
  await tester.pump();
  await tester.pump();
  expect(
    controller.phase,
    RoomPhase.connected,
    reason:
        'fixture is broken: the lobby rig must reach RoomPhase.connected; '
        'got ${controller.phase}',
  );
  return transport;
}

Future<void> _mountGame(
  WidgetTester tester,
  FeedbackSettings settings,
  FeedbackService service,
  Locale locale, {
  required bool finished,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = _newController(connector);
  addTearDown(controller.dispose);

  final Future<void> created = controller.createRoom(name: 'Host', players: 2);
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
      data: finished
          ? _roomJson(
              state: 'FINISHED',
              winner: 0,
              turn: _turnJson(seat: 0, phase: 'finished', deadlineMs: 0, k: 5),
            )
          : _roomJson(
              state: 'PLAYING',
              turn: _turnJson(
                seat: 0,
                phase: 'await_roll',
                deadlineMs: 45000,
                k: 0,
              ),
            ),
    ),
  );
  await created;
  await tester.pumpWidget(
    _wrap(
      child: GameScreen(controller: controller),
      settings: settings,
      service: service,
      locale: locale,
    ),
  );
  await tester.pump();
}

class _Rig {
  const _Rig(this.name, this.toggleKey, this.mount);

  final String name;
  final Key toggleKey;
  final _Mount mount;
}

final List<_Rig> _rigs = <_Rig>[
  const _Rig('home', Key('home-sound-toggle'), _mountHome),
  _Rig('lobby (host, connected)', const Key('lobby-sound-toggle'), (
    t,
    s,
    v,
    l,
  ) async {
    await _mountLobby(t, s, v, l, host: true);
  }),
  _Rig('lobby (guest, connected)', const Key('lobby-sound-toggle'), (
    t,
    s,
    v,
    l,
  ) async {
    await _mountLobby(t, s, v, l, host: false);
  }),
  _Rig(
    'lobby (stale: socket dropped, room held)',
    const Key('lobby-sound-toggle'),
    (t, s, v, l) async {
      final FakeTransport transport = await _mountLobby(t, s, v, l, host: true);
      transport.endFromFarSide();
      await t.pump();
      await t.pump();
    },
  ),
  _Rig(
    'game (playing)',
    const Key('game-sound-toggle'),
    (t, s, v, l) => _mountGame(t, s, v, l, finished: false),
  ),
  _Rig(
    'game (finished)',
    const Key('game-sound-toggle'),
    (t, s, v, l) => _mountGame(t, s, v, l, finished: true),
  ),
];

String _repro(String scenario, _Rig rig, Locale locale) {
  return 'Reproduce: scenario "$scenario", screen ${rig.name}, locale '
      '${locale.languageCode}, surface ${_surface.width.toInt()}x'
      '${_surface.height.toInt()} at 1.0, flutter test '
      'test/sound_toggle_test.dart --plain-name "$scenario". No random '
      'input is involved.';
}

void _usePhone(WidgetTester tester) {
  tester.view.physicalSize = _surface;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// One tap on the toggle, then a bounded pump long enough for any icon swap.
Future<void> _tapToggle(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.tap(find.byKey(key));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void _expectIcon(
  WidgetTester tester,
  Key key, {
  required bool on,
  required String when,
  required String repro,
}) {
  final Finder toggle = find.byKey(key);
  expect(
    find.descendant(
      of: toggle,
      matching: find.byIcon(
        on ? Icons.volume_up_rounded : Icons.volume_off_rounded,
      ),
    ),
    findsOneWidget,
    reason:
        'expected ${on ? 'volume_up_rounded' : 'volume_off_rounded'} '
        'in the toggle $when. $repro',
  );
  expect(
    find.descendant(
      of: toggle,
      matching: find.byIcon(
        on ? Icons.volume_off_rounded : Icons.volume_up_rounded,
      ),
    ),
    findsNothing,
    reason:
        'expected no ${on ? 'volume_off_rounded' : 'volume_up_rounded'} '
        'in the toggle $when. $repro',
  );
}

bool? _toggledFlag(WidgetTester tester, Key key) => tester
    .getSemantics(find.byKey(key))
    .flagsCollection
    .isToggled
    .toBoolOrNull();

// --- pixels (copied from home_plain_test.dart's idiom) ----------------------

Future<ByteData> _rgba(WidgetTester tester) async {
  RenderObject root = tester.renderObject(find.byType(Scaffold).first);
  while (root.parent != null) {
    root = root.parent!;
  }
  final OffsetLayer layer = root.debugLayer! as OffsetLayer;
  final Size size = tester.view.physicalSize;
  final ui.Image image = (await tester.runAsync(
    () => layer.toImage(Offset.zero & size, pixelRatio: 1.0),
  ))!;
  final ByteData? data = await tester.runAsync<ByteData?>(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  );
  return data!;
}

bool _paintsColor(ByteData data, int width, Rect rect, Color color) {
  final int r = (color.r * 255).round();
  final int g = (color.g * 255).round();
  final int b = (color.b * 255).round();
  for (int y = rect.top.floor(); y < rect.bottom.ceil(); y++) {
    for (int x = rect.left.floor(); x < rect.right.ceil(); x++) {
      final int i = (y * width + x) * 4;
      if (data.getUint8(i) == r &&
          data.getUint8(i + 1) == g &&
          data.getUint8(i + 2) == b &&
          data.getUint8(i + 3) == 255) {
        return true;
      }
    }
  }
  return false;
}

/// [testWidgets] with a semantics handle held for the whole body and
/// released in a finally inside it: the framework checks for live handles
/// before any addTearDown callback runs, so a tear-down dispose would fail
/// every case that uses it.
@isTest
void _semTest(
  String description,
  Future<void> Function(WidgetTester tester) body,
) {
  testWidgets(description, (WidgetTester tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    try {
      await body(tester);
    } finally {
      handle.dispose();
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  // ==========================================================================
  // D8: FeedbackSettings.muted
  // ==========================================================================
  group('FeedbackSettings.muted', () {
    // Red on 7501227: feedback.dart has no `muted` getter (the class ends its
    // members at :250-268, haptics and sound only).
    for (final (bool haptics, bool sound, bool muted) in <(bool, bool, bool)>[
      (true, true, false),
      (true, false, false),
      (false, true, false),
      (false, false, true),
    ]) {
      test('haptics $haptics, sound $sound reads muted $muted', () {
        final FeedbackSettings s = FeedbackSettings.forTest(
          haptics: haptics,
          sound: sound,
        );
        expect(
          s.muted,
          muted,
          reason:
              'expected muted == !haptics && !sound: haptics $haptics, '
              'sound $sound must read muted $muted; got ${s.muted}. '
              'Scenario: FeedbackSettings.forTest(haptics: $haptics, sound: '
              '$sound).',
        );
      });
    }

    test('muted = true turns both channels off and notifies exactly once', () {
      final FeedbackSettings s = FeedbackSettings.forTest();
      int notified = 0;
      s.addListener(() => notified += 1);
      s.muted = true;
      expect(
        (s.haptics, s.sound, s.muted),
        (false, false, true),
        reason:
            'expected muted = true to leave haptics false, sound false; got '
            'haptics ${s.haptics}, sound ${s.sound}. Scenario: forTest() '
            'then muted = true.',
      );
      expect(
        notified,
        1,
        reason:
            'expected exactly one listener notification for one muted '
            'assignment; got $notified (two would mean the setter went '
            'through haptics and sound separately). Scenario: forTest() '
            'then muted = true.',
      );
    });

    for (final (bool haptics, bool sound) in <(bool, bool)>[
      (false, false),
      (true, false),
      (false, true),
    ]) {
      test('muted = false from haptics $haptics, sound $sound turns both '
          'on and notifies once', () {
        final FeedbackSettings s = FeedbackSettings.forTest(
          haptics: haptics,
          sound: sound,
        );
        int notified = 0;
        s.addListener(() => notified += 1);
        s.muted = false;
        expect(
          (s.haptics, s.sound, s.muted),
          (true, true, false),
          reason:
              'expected muted = false to switch both channels on; got '
              'haptics ${s.haptics}, sound ${s.sound}. Scenario: forTest('
              'haptics: $haptics, sound: $sound) then muted = false.',
        );
        expect(
          notified,
          1,
          reason:
              'expected exactly one notification; got $notified. Scenario: '
              'forTest(haptics: $haptics, sound: $sound) then muted = false.',
        );
      });
    }

    test('muted = true from a half-on state still ends with both off', () {
      final FeedbackSettings s = FeedbackSettings.forTest(sound: false);
      s.muted = true;
      expect(
        (s.haptics, s.sound),
        (false, false),
        reason:
            'expected haptics false and sound false; got haptics '
            '${s.haptics}, sound ${s.sound}. Scenario: forTest(sound: '
            'false) then muted = true.',
      );
    });

    test('the separate setters still work and move muted with them', () {
      final FeedbackSettings s = FeedbackSettings.forTest();
      s.haptics = false;
      expect(s.muted, isFalse, reason: 'haptics off alone is not muted');
      s.sound = false;
      expect(
        s.muted,
        isTrue,
        reason:
            'expected haptics false then sound false to read muted. '
            'Scenario: forTest(), haptics = false, sound = false.',
      );
      s.haptics = true;
      expect(
        s.muted,
        isFalse,
        reason:
            'expected haptics back on to clear muted. Scenario: forTest(), '
            'haptics = false, sound = false, haptics = true.',
      );
    });

    test('a forTest instance never touches SharedPreferences', () async {
      final FeedbackSettings s = FeedbackSettings.forTest();
      s.muted = true;
      await pumpEventQueue();
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getKeys(),
        isEmpty,
        reason:
            'expected a forTest instance to write nothing; the store holds '
            '${prefs.getKeys()}. Scenario: forTest() then muted = true.',
      );
    });
  });

  // ==========================================================================
  // D8: load()
  // ==========================================================================
  group('FeedbackSettings.load', () {
    Future<FeedbackSettings> loadWith(Map<String, Object> values) {
      SharedPreferences.setMockInitialValues(values);
      return FeedbackSettings.load();
    }

    // Red on 7501227: feedback.dart:280-281 reads each key on its own
    // (`?? true`), so (false, true) loads as haptics false, sound true, and
    // there is no `muted` to read.
    test('both stored false starts muted', () async {
      final FeedbackSettings s = await loadWith(<String, Object>{
        'feedback.haptics': false,
        'feedback.sound': false,
      });
      expect(
        (s.muted, s.haptics, s.sound),
        (true, false, false),
        reason:
            'expected both stored false to load muted; got muted '
            '${s.muted}, haptics ${s.haptics}, sound ${s.sound}. Scenario: '
            'mock {feedback.haptics: false, feedback.sound: false}.',
      );
    });

    for (final (Map<String, Object> values, String label)
        in <(Map<String, Object>, String)>[
          (
            <String, Object>{'feedback.haptics': false, 'feedback.sound': true},
            'haptics false, sound true',
          ),
          (
            <String, Object>{'feedback.haptics': true, 'feedback.sound': false},
            'haptics true, sound false',
          ),
          (
            <String, Object>{'feedback.haptics': false},
            'haptics false, sound absent',
          ),
          (
            <String, Object>{'feedback.sound': false},
            'sound false, haptics absent',
          ),
          (
            <String, Object>{'feedback.haptics': true, 'feedback.sound': true},
            'both true',
          ),
          (<String, Object>{}, 'both absent'),
        ]) {
      test('$label loads not muted with both channels on', () async {
        final FeedbackSettings s = await loadWith(values);
        expect(
          (s.muted, s.haptics, s.sound),
          (false, true, true),
          reason:
              'expected $label to load on/on (X109 migration: only both '
              'false stays muted); got muted ${s.muted}, haptics '
              '${s.haptics}, sound ${s.sound}. Scenario: mock $values.',
        );
      });
    }

    test('load writes nothing back, migrated or not', () async {
      for (final Map<String, Object> values in <Map<String, Object>>[
        <String, Object>{'feedback.haptics': false, 'feedback.sound': true},
        <String, Object>{'feedback.haptics': false, 'feedback.sound': false},
        <String, Object>{},
      ]) {
        await loadWith(values);
        await pumpEventQueue();
        final SharedPreferences prefs = await SharedPreferences.getInstance();
        await prefs.reload();
        expect(
          <String, Object?>{
            for (final String k in prefs.getKeys()) k: prefs.get(k),
          },
          values,
          reason:
              'expected load() to leave the store exactly as it was '
              '($values); it holds ${prefs.getKeys()}. Scenario: mock '
              '$values then load().',
        );
      }
    });

    test('muted = true on a loaded instance persists both keys false and '
        'a fresh load reads muted', () async {
      final FeedbackSettings s = await loadWith(<String, Object>{});
      s.muted = true;
      await pumpEventQueue();
      SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(
        (prefs.getBool('feedback.haptics'), prefs.getBool('feedback.sound')),
        (false, false),
        reason:
            'expected the store to hold haptics false and sound false after '
            'muted = true; got haptics ${prefs.getBool('feedback.haptics')}, '
            'sound ${prefs.getBool('feedback.sound')}. Scenario: load() on '
            'an empty store then muted = true.',
      );
      final FeedbackSettings relaunched = await FeedbackSettings.load();
      expect(
        relaunched.muted,
        isTrue,
        reason:
            'expected a fresh load() to read muted (mute survives a '
            'relaunch). Scenario: load() on an empty store, muted = true, '
            'then load() again.',
      );

      relaunched.muted = false;
      await pumpEventQueue();
      prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(
        (prefs.getBool('feedback.haptics'), prefs.getBool('feedback.sound')),
        (true, true),
        reason:
            'expected the store to hold both true after muted = false; got '
            'haptics ${prefs.getBool('feedback.haptics')}, sound '
            '${prefs.getBool('feedback.sound')}. Scenario: muted = true, '
            'load(), muted = false.',
      );
      expect(
        (await FeedbackSettings.load()).muted,
        isFalse,
        reason: 'expected a load() after unmute to read not muted.',
      );
    });

    test('a half-on legacy store, once muted, persists both false', () async {
      final FeedbackSettings s = await loadWith(<String, Object>{
        'feedback.haptics': true,
        'feedback.sound': false,
      });
      expect(s.muted, isFalse);
      s.muted = true;
      await pumpEventQueue();
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(
        (prefs.getBool('feedback.haptics'), prefs.getBool('feedback.sound')),
        (false, false),
        reason:
            'expected muted = true to overwrite the legacy half-on store '
            'with both false; got haptics ${prefs.getBool('feedback.haptics')}'
            ', sound ${prefs.getBool('feedback.sound')}. Scenario: mock '
            '{haptics: true, sound: false}, load(), muted = true.',
      );
    });
  });

  // ==========================================================================
  // D7: the button on its own
  // ==========================================================================
  group('SoundToggleButton', () {
    Future<void> pumpBare(WidgetTester tester, Widget toggle) async {
      _usePhone(tester);
      await tester.pumpWidget(
        _wrap(
          child: Scaffold(body: Center(child: toggle)),
          settings: FeedbackSettings.forTest(),
          service: const NoopFeedbackService(),
          locale: const Locale('en'),
        ),
      );
      await tester.pump();
    }

    // Red on 7501227: lib/src/sound_toggle.dart does not exist.
    testWidgets('the style parameter paints the caller\'s frame', (
      tester,
    ) async {
      const Color frame = Color(0xFF00AA11);
      const String repro =
          'Reproduce: scenario "style parameter", flutter test '
          'test/sound_toggle_test.dart --plain-name "style parameter". No '
          'random input is involved.';
      await pumpBare(
        tester,
        SoundToggleButton(
          key: const Key('bare-toggle'),
          style: IconButton.styleFrom(backgroundColor: frame),
        ),
      );
      final Rect rect = tester.getRect(find.byKey(const Key('bare-toggle')));
      final int width = _surface.width.toInt();
      expect(
        _paintsColor(await _rgba(tester), width, rect, frame),
        isTrue,
        reason:
            'expected SoundToggleButton(style: ...backgroundColor $frame) '
            'to paint that colour inside its $rect; none of its pixels '
            'match. $repro',
      );

      await pumpBare(tester, const SoundToggleButton(key: Key('bare-toggle')));
      expect(
        _paintsColor(
          await _rgba(tester),
          width,
          tester.getRect(find.byKey(const Key('bare-toggle'))),
          frame,
        ),
        isFalse,
        reason:
            'fixture: with no style the control must not paint the colour '
            '$frame, or the case above proves nothing. $repro',
      );
    });
  });

  // ==========================================================================
  // D7: per screen
  // ==========================================================================
  for (final _Rig rig in _rigs) {
    for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
      final String lc = locale.languageCode;
      final String label = lc == 'ar' ? _labelAr : _labelEn;

      group('${rig.name}, $lc', () {
        // Red on 7501227: the key does not exist; the screen builds
        // home-settings-button (home_screen.dart:1243), lobby-settings-button
        // (lobby_screen.dart:444) or game-settings-button (game_screen.dart:
        // 3652) with Icons.tune_rounded, each opening
        // showFeedbackSettingsSheet.
        _semTest('the toggle is there, on, 48 dp, labelled, and none of '
            'the settings-sheet keys remain', (tester) async {
          const String name = 'toggle shape';
          final String repro = _repro(name, rig, locale);
          _usePhone(tester);
          final FeedbackSettings settings = FeedbackSettings.forTest();
          await rig.mount(tester, settings, _ProbeService(settings), locale);

          final Finder toggle = find.byKey(rig.toggleKey);
          expect(
            toggle,
            findsOneWidget,
            reason:
                'expected exactly one ${rig.toggleKey}; found '
                '${toggle.evaluate().length}. $repro',
          );
          _expectIcon(
            tester,
            rig.toggleKey,
            on: true,
            when: 'with sound on',
            repro: repro,
          );
          final Size size = tester.getSize(toggle);
          expect(
            size.width >= 48 && size.height >= 48,
            isTrue,
            reason:
                'expected the toggle at least 48 x 48 dp; got $size. '
                '$repro',
          );
          expect(
            find.descendant(
              of: toggle,
              matching: find.byType(Text, skipOffstage: false),
            ),
            findsNothing,
            reason: 'expected no text label inside the toggle. $repro',
          );

          final AppLocalizations loc = AppLocalizations.of(
            tester.element(toggle),
          );
          expect(
            loc.soundToggleLabel,
            label,
            reason: 'D9: soundToggleLabel has the wrong wording. $repro',
          );
          final SemanticsNode node = tester.getSemantics(toggle);
          expect(
            node.flagsCollection.isButton,
            isTrue,
            reason: 'expected the toggle to be a semantics button. $repro',
          );
          expect(
            node.flagsCollection.isToggled.toBoolOrNull(),
            isTrue,
            reason:
                'expected semantics toggled == true with sound on '
                '(toggled: !muted). $repro',
          );
          expect(
            node.label.trim(),
            label,
            reason:
                'expected the semantics label "$label"; got "${node.label}". '
                '$repro',
          );
          expect(
            find.descendant(of: toggle, matching: find.byTooltip(label)),
            findsOneWidget,
            reason: 'expected the tooltip "$label" on the toggle. $repro',
          );

          for (final String key in _removedKeys) {
            expect(
              find.byKey(Key(key), skipOffstage: false),
              findsNothing,
              reason: 'expected no widget keyed $key; found one. $repro',
            );
          }
          expect(
            find.byIcon(Icons.tune_rounded, skipOffstage: false),
            findsNothing,
            reason: 'expected no tune_rounded settings glyph. $repro',
          );
        });

        // Red on 7501227: no toggle to tap; the old button opens a sheet and
        // never sets both channels together (feedback.dart:252, :262).
        _semTest('one tap mutes both channels, plays no cue; the second '
            'tap unmutes both and plays exactly one tap, after the flip', (
          tester,
        ) async {
          const String name = 'tap twice';
          final String repro = _repro(name, rig, locale);
          _usePhone(tester);
          final FeedbackSettings settings = FeedbackSettings.forTest();
          final _ProbeService service = _ProbeService(settings);
          await rig.mount(tester, settings, service, locale);
          service.clear();

          await _tapToggle(tester, rig.toggleKey);
          expect(
            (settings.haptics, settings.sound, settings.muted),
            (false, false, true),
            reason:
                'expected one tap to turn haptics and sound off together; '
                'got haptics ${settings.haptics}, sound ${settings.sound}. '
                '$repro',
          );
          _expectIcon(
            tester,
            rig.toggleKey,
            on: false,
            when: 'after one tap',
            repro: repro,
          );
          expect(
            _toggledFlag(tester, rig.toggleKey),
            isFalse,
            reason: 'expected semantics toggled == false once muted. $repro',
          );
          expect(
            service.cues,
            isEmpty,
            reason:
                'expected turning sound OFF to play nothing; the service '
                'saw ${service.cues}. $repro',
          );

          await _tapToggle(tester, rig.toggleKey);
          expect(
            (settings.haptics, settings.sound, settings.muted),
            (true, true, false),
            reason:
                'expected the second tap to turn both back on; got haptics '
                '${settings.haptics}, sound ${settings.sound}. $repro',
          );
          _expectIcon(
            tester,
            rig.toggleKey,
            on: true,
            when: 'after the second tap',
            repro: repro,
          );
          expect(
            _toggledFlag(tester, rig.toggleKey),
            isTrue,
            reason: 'expected semantics toggled == true once unmuted. $repro',
          );
          expect(
            service.cues,
            <FeedbackCue>[FeedbackCue.tap],
            reason:
                'expected exactly one FeedbackCue.tap when turning sound '
                'ON; the service saw ${service.cues}. $repro',
          );
          expect(
            service.mutedAtPlay,
            <bool>[false],
            reason:
                'expected the tap cue to play after the flip (muted false '
                'at play time); it was played with muted '
                '${service.mutedAtPlay}. $repro',
          );
        });

        // Red on 7501227: no toggle, no `muted`.
        _semTest('starting muted shows volume_off, toggled false; one tap '
            'unmutes and plays one tap', (tester) async {
          const String name = 'start muted';
          final String repro = _repro(name, rig, locale);
          _usePhone(tester);
          final FeedbackSettings settings = FeedbackSettings.forTest(
            haptics: false,
            sound: false,
          );
          final _ProbeService service = _ProbeService(settings);
          await rig.mount(tester, settings, service, locale);
          service.clear();

          _expectIcon(
            tester,
            rig.toggleKey,
            on: false,
            when: 'when the app starts muted',
            repro: repro,
          );
          expect(
            _toggledFlag(tester, rig.toggleKey),
            isFalse,
            reason: 'expected toggled == false when starting muted. $repro',
          );
          await _tapToggle(tester, rig.toggleKey);
          expect(
            (settings.haptics, settings.sound),
            (true, true),
            reason: 'expected a tap on a muted app to switch both on. $repro',
          );
          expect(
            service.cues,
            <FeedbackCue>[FeedbackCue.tap],
            reason:
                'expected one tap cue on unmuting; the service saw '
                '${service.cues}. $repro',
          );
        });

        // Red on 7501227: no toggle; the old sheet could leave exactly one
        // channel on, which D8 turns into "not muted".
        for (final (bool haptics, bool sound) in <(bool, bool)>[
          (true, false),
          (false, true),
        ]) {
          testWidgets('half-on (haptics $haptics, sound $sound) reads as '
              'on; a tap mutes both and plays nothing', (tester) async {
            final String name = 'half on $haptics $sound';
            final String repro = _repro(name, rig, locale);
            _usePhone(tester);
            final FeedbackSettings settings = FeedbackSettings.forTest(
              haptics: haptics,
              sound: sound,
            );
            final _ProbeService service = _ProbeService(settings);
            await rig.mount(tester, settings, service, locale);
            service.clear();

            _expectIcon(
              tester,
              rig.toggleKey,
              on: true,
              when: 'for a half-on store (muted is false)',
              repro: repro,
            );
            await _tapToggle(tester, rig.toggleKey);
            expect(
              (settings.haptics, settings.sound, settings.muted),
              (false, false, true),
              reason:
                  'expected a tap on a half-on state to mute both channels; '
                  'got haptics ${settings.haptics}, sound ${settings.sound}. '
                  '$repro',
            );
            expect(
              service.cues,
              isEmpty,
              reason:
                  'expected muting to play nothing; saw ${service.cues}. '
                  '$repro',
            );
          });
        }

        // Red on 7501227: no toggle.
        testWidgets('four taps: off, on, off, on plays exactly two taps, '
            'each on an unmute', (tester) async {
          const String name = 'four taps';
          final String repro = _repro(name, rig, locale);
          _usePhone(tester);
          final FeedbackSettings settings = FeedbackSettings.forTest();
          final _ProbeService service = _ProbeService(settings);
          await rig.mount(tester, settings, service, locale);
          service.clear();

          final List<bool> mutedAfter = <bool>[];
          for (int i = 0; i < 4; i++) {
            await _tapToggle(tester, rig.toggleKey);
            mutedAfter.add(settings.muted);
          }
          expect(
            mutedAfter,
            <bool>[true, false, true, false],
            reason:
                'expected the toggle to alternate muted after each tap; got '
                '$mutedAfter. $repro',
          );
          expect(
            service.cues,
            <FeedbackCue>[FeedbackCue.tap, FeedbackCue.tap],
            reason:
                'expected one tap cue per unmute (two in four taps); the '
                'service saw ${service.cues}. $repro',
          );
          _expectIcon(
            tester,
            rig.toggleKey,
            on: true,
            when: 'after four taps',
            repro: repro,
          );
        });
      });
    }
  }

  // ==========================================================================
  // D7 + D8 together: a mute made from the screen is the persisted mute
  // ==========================================================================
  testWidgets('a tap on home-sound-toggle over a loaded FeedbackSettings '
      'writes both keys false, and the next launch comes up muted', (
    tester,
  ) async {
    const String repro =
        'Reproduce: scenario "toggle persists", flutter test '
        'test/sound_toggle_test.dart --plain-name "toggle over a loaded". '
        'No random input is involved.';
    _usePhone(tester);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final FeedbackSettings settings = await FeedbackSettings.load();
    await _mountHome(
      tester,
      settings,
      _ProbeService(settings),
      const Locale('en'),
    );
    await _tapToggle(tester, const Key('home-sound-toggle'));
    await tester.runAsync(() => pumpEventQueue());
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    expect(
      (prefs.getBool('feedback.haptics'), prefs.getBool('feedback.sound')),
      (false, false),
      reason:
          'expected the store to hold both keys false after the tap; got '
          'haptics ${prefs.getBool('feedback.haptics')}, sound '
          '${prefs.getBool('feedback.sound')}. $repro',
    );

    final FeedbackSettings relaunched = await FeedbackSettings.load();
    await _mountHome(
      tester,
      relaunched,
      _ProbeService(relaunched),
      const Locale('en'),
    );
    _expectIcon(
      tester,
      const Key('home-sound-toggle'),
      on: false,
      when: 'on the launch after muting',
      repro: repro,
    );
  });
}
