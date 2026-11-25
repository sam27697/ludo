// Rig shared by the C-701 home and waiting-window tests.
//
// A real HomeScreen over a RoomController whose transport is the project's
// FakeTransport, speaking the wire format of docs/PROTOCOL.md sections 33 and
// 34. Nothing here mocks the home: the tests tap its real buttons, read the
// frames the controller really sends, and answer them with frames the server
// would send.
//
// Every wait is on a condition in bounded 50 ms steps. Every failure message
// carries [C701Rig.repro]: the variant (locale, size, text scale), the row
// name and the command that reruns just that row.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart'
    show appSupportedLocales, buildAppTheme;
import 'package:ludo_client/src/deep_link.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../net/fake_transport.dart';
import 'home_flow.dart';

const Key queueSheetKey = Key('queue-sheet');
const Key queueAheadKey = Key('queue-ahead');
const Key queueVsComputerKey = Key('queue-vs-computer');
const Key queueCancelKey = Key('queue-cancel');
const Key vsComputerTwoKey = Key('vs-computer-2');
const Key vsComputerFourKey = Key('vs-computer-4');
const Key vsComputerBackKey = Key('vs-computer-back');
const Key homeNoticeKey = Key('home-notice');
const Key homeCodeBanKey = Key('home-code-ban');
const Key homeLastGameKey = Key('home-last-game');
const Key homeJoinDividerKey = Key('home-join-divider');

const String c701ServerUrl = 'wss://c701-test.invalid/ws';

/// One cell of the matrix every row runs over.
class C701Variant {
  const C701Variant(this.locale, this.size, {this.scale = 1.0});

  final Locale locale;
  final Size size;
  final double scale;

  String get lang => locale.languageCode;

  String get id =>
      '$lang ${size.width.toInt()}x${size.height.toInt()}'
      '${scale == 1.0 ? '' : ' scale $scale'}';

  C701Variant withScale(double s) => C701Variant(locale, size, scale: s);
}

const Size kSmallPhone = Size(320, 640);
const Size kLargePhone = Size(412, 915);

/// English and Arabic at 320x640 and at 412x915, normal text.
const List<C701Variant> kVariants = <C701Variant>[
  C701Variant(Locale('en'), kSmallPhone),
  C701Variant(Locale('ar'), kSmallPhone),
  C701Variant(Locale('en'), kLargePhone),
  C701Variant(Locale('ar'), kLargePhone),
];

/// The same four at text scale 1.3.
final List<C701Variant> kLargeTextVariants = <C701Variant>[
  for (final C701Variant v in kVariants) v.withScale(1.3),
];

Map<String, Object?> decodeFrame(String raw) =>
    jsonDecode(raw) as Map<String, Object?>;

String frameType(String raw) => decodeFrame(raw)['t']! as String;

Map<String, Object?> frameData(String raw) =>
    (decodeFrame(raw)['d'] ?? const <String, Object?>{})
        as Map<String, Object?>;

/// The shape section 31 item 2 gives an `install`.
final RegExp installShape = RegExp(r'^[A-Za-z0-9_-]{16,64}$');

/// The shape `set_seed` gives a `client_seed` (section 11).
final RegExp clientSeedShape = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

/// A RoomController that remembers its dispose: home retires the controllers
/// it owns, and a ChangeNotifier refuses a second dispose.
class TrackedController extends RoomController {
  TrackedController({
    required super.serverUrl,
    required super.connect,
    super.autoReconnectDelays,
  });

  bool wasDisposed = false;

  @override
  void dispose() {
    wasDisposed = true;
    super.dispose();
  }
}

class C701Rig {
  C701Rig(
    this.tester,
    this.variant, {
    required this.file,
    required this.row,
    this.reconnectDelays = kAutoReconnectDelays,
  });

  final WidgetTester tester;
  final C701Variant variant;
  final String file;
  final String row;
  final List<Duration> reconnectDelays;

  final List<FakeTransport> transports = <FakeTransport>[];
  final List<TrackedController> controllers = <TrackedController>[];

  /// Connect calls that should fail (the socket cannot be opened).
  bool failConnects = false;

  /// Taps made through [tap]: the P5 count.
  int taps = 0;
  int _serverIds = 0;

  String get repro =>
      'variant "${variant.id}", row "$row"; rerun: cd packages/ludo_client '
      '&& flutter test test/$file --plain-name "$row"';

  RoomController call() {
    final TrackedController c = TrackedController(
      serverUrl: Uri.parse(c701ServerUrl),
      autoReconnectDelays: reconnectDelays,
      connect: (Uri url) async {
        if (failConnects) {
          throw StateError('c701 rig: connect refused by the test');
        }
        final FakeTransport t = FakeTransport();
        transports.add(t);
        return t;
      },
    );
    controllers.add(c);
    return c;
  }

  // ---- mounting ---------------------------------------------------------

  Future<void> mount({
    Map<String, Object> prefs = const <String, Object>{},
    Future<Uri?> Function()? initialLink,
    Stream<Uri> Function()? linkStream,
    DateTime Function()? clock,
    bool keepPrefs = false,
    bool reduceMotion = false,
  }) async {
    if (!keepPrefs) {
      SharedPreferences.setMockInitialValues(<String, Object>{...prefs});
    }
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = variant.size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        locale: variant.locale,
        supportedLocales: appSupportedLocales,
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        builder: (BuildContext context, Widget? child) {
          return MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(variant.scale),
              disableAnimations: reduceMotion,
            ),
            child: child!,
          );
        },
        home: HomeScreen(
          onToggleLocale: () {},
          controllerFactory: call,
          initialLinkReader: initialLink ?? noInitialLink,
          linkStream: linkStream ?? noLinkStream,
          clock: clock,
        ),
      ),
    );
    for (int i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Ends the case: flushes request timers, unmounts, disposes controllers.
  Future<void> finish() async {
    await tester.pump(const Duration(seconds: 40));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    for (final TrackedController c in controllers) {
      if (!c.wasDisposed) {
        c.dispose();
      }
    }
    await tester.pump();
  }

  AppLocalizations get loc =>
      AppLocalizations.of(tester.element(find.byType(HomeScreen)));

  String get defaultName => oldDefaultName(variant.lang);

  // ---- waiting ----------------------------------------------------------

  Future<void> waitUntil(bool Function() cond, String what) async {
    for (int i = 0; i < 80; i++) {
      if (cond()) return;
      await tester.pump(const Duration(milliseconds: 50));
    }
    if (cond()) return;
    fail('waited 4000 ms for $what and it did not happen. $repro');
  }

  /// Pumps one second at a time up to [limit] until [cond] holds (for the
  /// reconnect backoff, which is measured in seconds on the fake clock).
  Future<void> waitSeconds(
    bool Function() cond,
    String what, {
    int limit = 40,
  }) async {
    for (int i = 0; i < limit; i++) {
      if (cond()) return;
      await tester.pump(const Duration(seconds: 1));
    }
    if (cond()) return;
    fail(
      'waited $limit s of fake time for $what and it did not happen. $repro',
    );
  }

  // ---- frames -----------------------------------------------------------

  FakeTransport get transport {
    expect(
      transports,
      isNotEmpty,
      reason: 'expected a transport to have been opened. $repro',
    );
    return transports.last;
  }

  /// Every frame of [type] sent over every transport, in order.
  List<Map<String, Object?>> sent(String type) => <Map<String, Object?>>[
    for (final FakeTransport t in transports)
      for (final String raw in t.sentRaw)
        if (frameType(raw) == type) decodeFrame(raw),
  ];

  List<String> sentTypes() => <String>[
    for (final FakeTransport t in transports)
      for (final String raw in t.sentRaw) frameType(raw),
  ];

  String frame(String type, Map<String, Object?> data, {String? re}) {
    _serverIds += 1;
    return jsonEncode(<String, Object?>{
      'v': 1,
      't': type,
      'id': 'c701-srv-${_serverIds.toString().padLeft(6, '0')}',
      're': ?re,
      'd': data,
    });
  }

  Future<void> push(
    String type,
    Map<String, Object?> data, {
    String? re,
    FakeTransport? on,
  }) async {
    (on ?? transport).pushText(frame(type, data, re: re));
    await tester.pump();
    await tester.pump();
  }

  Future<void> pushError(String code, {required String re}) =>
      push('error', <String, Object?>{'code': code, 'message': code}, re: re);

  Future<void> pushQueued(
    int position, {
    String ticket = 'tkt0123456789abcdefghij',
    String? re,
  }) => push('queued', <String, Object?>{
    'ticket': ticket,
    'position': position,
  }, re: re);

  Map<String, Object?> seatJson(int seat, String name) => <String, Object?>{
    'seat': seat,
    'name': name,
    'connected': true,
    'tokens': const <int>[-1, -1, -1, -1],
    'client_seed': null,
    'seed_origin': null,
  };

  Map<String, Object?> roomJson({
    String code = 'K7M2QP',
    int players = 4,
    bool open = true,
    int mySeat = 1,
  }) => <String, Object?>{
    'code': code,
    'state': 'LOBBY',
    'host_seat': 0,
    'players': players,
    'open': open,
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
      if (mySeat != 0) seatJson(0, 'Host'),
      seatJson(mySeat, defaultName),
    ],
    'turn': null,
    'winner': null,
    'seq': 1,
  };

  // ---- driving ----------------------------------------------------------

  /// Types the name the frames expect, as a player would.
  Future<void> typeName([String? name]) =>
      enterName(tester, name ?? defaultName);

  /// One counted tap on the widget at [finder], after it is on screen and at
  /// rest.
  Future<void> tap(Finder finder, {required String what}) async {
    await pumpUntilAtRest(tester, finder, what: what);
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
    taps += 1;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> openCreateSheet() async {
    await tap(find.byKey(createRoomButtonKey), what: 'create-room-button');
    await pumpUntilAtRest(
      tester,
      find.byKey(createRoomSheetKey),
      what: 'create-room-sheet. $repro',
    );
  }

  Future<void> openJoinSheet() async {
    await tap(find.byKey(joinGameButtonKey), what: 'join-game-button');
    await pumpUntilAtRest(
      tester,
      find.byKey(joinSheetKey),
      what: 'join-sheet. $repro',
    );
  }

  Future<void> openCodeEntryCounted() async {
    await openJoinSheet();
    await tap(find.byKey(joinCodeTileKey), what: 'join-code-tile');
    await pumpUntilAtRest(
      tester,
      find.byKey(roomCodeFieldKey),
      what: 'room-code-field in the join sheet. $repro',
    );
  }

  /// Join sheet, random tile, up to the waiting window.
  Future<void> enterQueue() async {
    await openJoinSheet();
    await tap(find.byKey(joinRandomTileKey), what: 'join-random-tile');
    await pumpUntilFound(
      tester,
      find.byKey(queueSheetKey),
      what: 'queue-sheet after join-random-tile. $repro',
    );
    await waitUntil(
      () => sent('find_game').isNotEmpty,
      'a find_game frame after join-random-tile',
    );
  }

  /// The id of the last frame of [type] the client sent, to answer it.
  String idOfLast(String type) {
    final List<Map<String, Object?>> all = sent(type);
    expect(all, isNotEmpty, reason: 'no $type was sent. $repro');
    return all.last['id']! as String;
  }

  /// Text scale and overflow guard: nothing threw during layout, and every
  /// keyed widget in [keys] lies inside the screen's width.
  void expectNoOverflow(String where, {List<Key> keys = const <Key>[]}) {
    final Object? error = tester.takeException();
    expect(
      error,
      isNull,
      reason:
          'expected no overflow or layout error at $where, got: $error. '
          '$repro',
    );
    for (final Key key in keys) {
      final Finder f = find.byKey(key);
      if (f.evaluate().isEmpty) continue;
      final Rect r = tester.getRect(f.first);
      expect(
        r.left >= -0.5 && r.right <= variant.size.width + 0.5,
        isTrue,
        reason:
            '$where: $key spans ${r.left}..${r.right}, outside the '
            '0..${variant.size.width} screen. $repro',
      );
    }
  }
}

/// Runs [body] and always finishes the rig.
Future<void> runRow(C701Rig rig, Future<void> Function() body) async {
  try {
    await body();
  } finally {
    await rig.finish();
  }
}
