// A black-box WebSocket harness for tests that speak the wire protocol of
// `docs/PROTOCOL.md` directly, against a real, running `WireServer`, rather
// than calling into `RoomRegistry` in-process. Nothing here imports a message
// type or a field name that is specific to any one message: every test that
// uses this file builds its own JSON `d` maps and reads the JSON `d` maps it
// gets back, exactly as a real client would. That is deliberate: a test built
// this way cannot pass by accident just because it happens to share a typo
// with the code it is testing.
//
// Modelled on `health_test.dart`'s own `_Harness`, which is the only other
// place in this package that starts a real `WireServer` for a test. That
// class stays private to its own file; this one is shared because more than
// one wire-level suite needs the same plumbing.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

/// One running server for the lifetime of a single test: a fresh
/// [RoomRegistry], [RateLimiter] and [FakeClock], and the [WireServer] that
/// wires them to a real listening socket. `build` does not start the server;
/// call [start] once the caller is ready to connect clients to it.
class ServerHarness {
  ServerHarness._(this.clock, this.registry, this.server);

  final FakeClock clock;
  final RoomRegistry registry;
  final WireServer server;

  /// [secure] is additive, order 052: `RoomRegistry` has always taken
  /// `required Random secure` (`lib/src/registry.dart:284`), and every
  /// existing call site of this method calls it with no arguments and gets
  /// exactly what it always got, `Random.secure()`. A caller that supplies
  /// [secure] -- `test/support/scripted_bytes.dart`'s
  /// `ScriptedBytesRandom`, so far the only one -- gets a room whose whole
  /// draw sequence, and therefore whose whole die-face sequence, is fixed
  /// rather than drawn from real entropy. Nothing under `lib/` or `bin/`
  /// is aware this parameter exists.
  static ServerHarness build({Random? secure}) {
    final FakeClock clock = FakeClock(DateTime.utc(2026, 8, 28));
    final RoomRegistry registry =
        RoomRegistry(clock: clock, secure: secure ?? Random.secure());
    final RateLimiter rateLimiter = RateLimiter(clock: clock);
    final WireServer server = WireServer(
      registry: registry,
      rateLimiter: rateLimiter,
      clock: clock,
    );
    return ServerHarness._(clock, registry, server);
  }

  /// Binds an ephemeral loopback port. Safe to call exactly once per
  /// instance; a second call would try to bind again and fail.
  Future<void> start() =>
      server.start(address: InternetAddress.loopbackIPv4, port: 0);

  /// The `ws://` root a client dials to reach this server. Only meaningful
  /// after [start] has completed.
  Uri get wsUri =>
      Uri(scheme: 'ws', host: '127.0.0.1', port: server.port, path: '/');

  Future<void> close() => server.close();
}

/// Delivers decoded frames to whichever `next()` call is waiting for one,
/// in arrival order, buffering anything that arrives with nobody waiting.
/// This is the entire ordering guarantee a test can rely on: frames are
/// handed out in the order the socket produced them, never reordered and
/// never dropped.
class _FrameQueue {
  _FrameQueue(Stream<Map<String, Object?>> source) {
    _subscription = source.listen(
      (Map<String, Object?> frame) {
        if (_waiting.isNotEmpty) {
          _waiting.removeAt(0).complete(frame);
        } else {
          _buffered.add(frame);
        }
      },
      onDone: () {
        _done = true;
        for (final Completer<Map<String, Object?>> completer in _waiting) {
          completer.completeError(
            StateError('socket closed before a frame arrived'),
          );
        }
        _waiting.clear();
      },
      onError: (Object error, StackTrace stackTrace) {
        for (final Completer<Map<String, Object?>> completer in _waiting) {
          completer.completeError(error, stackTrace);
        }
        _waiting.clear();
      },
    );
  }

  late final StreamSubscription<Map<String, Object?>> _subscription;
  final List<Map<String, Object?>> _buffered = <Map<String, Object?>>[];
  final List<Completer<Map<String, Object?>>> _waiting =
      <Completer<Map<String, Object?>>>[];
  bool _done = false;

  Future<Map<String, Object?>> next() {
    if (_buffered.isNotEmpty) {
      return Future<Map<String, Object?>>.value(_buffered.removeAt(0));
    }
    if (_done) {
      return Future<Map<String, Object?>>.error(
        StateError('socket already closed and no frame was pending'),
      );
    }
    final Completer<Map<String, Object?>> completer =
        Completer<Map<String, Object?>>();
    _waiting.add(completer);
    return completer.future;
  }

  Future<void> close() => _subscription.cancel();
}

/// A real WebSocket client speaking the envelope shape of
/// `docs/PROTOCOL.md` section 1: `{ "v": 1, "t": ..., "id": ..., "d": ... }`
/// out, the same shape plus an optional `re` in. Every message id this
/// client mints is a plain, deterministic counter, `test-msg-<n>`, well
/// inside the 8-to-64-character `[A-Za-z0-9_-]` id shape the protocol
/// requires -- there is nothing random in it, so a failure that names the
/// id is reproducible by re-running the same test.
class WireTestClient {
  WireTestClient._(this._socket, this._queue);

  final WebSocket _socket;
  final _FrameQueue _queue;
  int _idCounter = 0;

  static Future<WireTestClient> connect(Uri uri) async {
    final WebSocket socket = await WebSocket.connect(uri.toString());
    final Stream<Map<String, Object?>> decoded = socket.map(
      (Object? raw) => jsonDecode(raw! as String) as Map<String, Object?>,
    );
    return WireTestClient._(socket, _FrameQueue(decoded));
  }

  /// Sends one client-to-server frame and returns the `id` it was sent
  /// with, so a caller can assert a reply's `re` matches it.
  String send(String type, Map<String, Object?> data, {String? id}) {
    final String messageId = id ?? 'test-msg-${++_idCounter}';
    _socket.add(jsonEncode(<String, Object?>{
      'v': 1,
      't': type,
      'id': messageId,
      'd': data,
    }));
    return messageId;
  }

  /// The next frame this socket receives, decoded, in arrival order. Bounded
  /// by [timeout] so a frame the server never sends fails the test promptly
  /// rather than hanging the suite -- this is a liveness bound on a real
  /// socket, not a fixed sleep standing in for a condition.
  Future<Map<String, Object?>> next({
    Duration timeout = const Duration(seconds: 3),
  }) {
    return _queue.next().timeout(
          timeout,
          onTimeout: () => throw TestFailure(
            'expected another frame on this socket within $timeout and none '
            'arrived',
          ),
        );
  }

  Future<void> close() async {
    await _queue.close();
    if (_socket.readyState == WebSocket.open) {
      await _socket.close();
    }
  }
}

// -----------------------------------------------------------------------
// Additive helpers below this line, added for order 046 (the turn loop
// conformance suite, `docs/PROTOCOL.md` section 12) so that more than one
// `turn_loop_*.dart` file can share the same two-seat-lobby plumbing rather
// than each re-deriving its own private copy of it, the way
// `fairness_lobby_test.dart` did for section 11. Nothing above this line
// was changed to add them; every existing symbol in this file keeps its
// exact prior signature and behaviour, which is what the six other test
// files that already import this one depend on.
// -----------------------------------------------------------------------

/// One seat in a room reachable over the wire: the socket that took or
/// resumed it, the seat index the registry assigned, and the seat token
/// that reclaims it (`docs/PROTOCOL.md` section 2). General-purpose, not
/// specific to any one section of the protocol.
class WireTestSeat {
  WireTestSeat({required this.client, required this.seat, required this.token});

  final WireTestClient client;
  final int seat;
  final String token;
}

/// A room in LOBBY with exactly two seats filled, every handshake frame
/// already drained from both sockets' queues -- host and guest are ready
/// for a caller to send the one message it actually wants to observe.
class WireTestLobby {
  WireTestLobby({
    required this.code,
    required this.host,
    required this.guest,
    required this.hostRoom,
    required this.guestRoom,
  });

  final String code;
  final WireTestSeat host;
  final WireTestSeat guest;

  /// The `d` of the `room` frame the host received on `create_room`.
  final Map<String, Object?> hostRoom;

  /// The `d` of the `room` frame the guest received on `join_room`.
  final Map<String, Object?> guestRoom;
}

/// Creates a fresh room over [uri] and joins a second client into it,
/// draining every handshake frame (`seat_assigned`, both `room` frames, and
/// the host's `player_joined` push for the guest) so a caller is left with
/// two sockets ready for whatever it actually wants to test. Every socket
/// opened here is appended to [clients], exactly as a caller opening a
/// [WireTestClient] by hand would do, so a `tearDown` that already closes
/// everything in that list closes these too.
Future<WireTestLobby> buildWireTestLobby(
  Uri uri,
  List<WireTestClient> clients, {
  String hostName = 'Host',
  String guestName = 'Guest',
  int players = 2,
  Map<String, Object?> rules = const <String, Object?>{},
}) async {
  final WireTestClient hostClient = await WireTestClient.connect(uri);
  clients.add(hostClient);
  hostClient.send('create_room', <String, Object?>{
    'name': hostName,
    'players': players,
    if (rules.isNotEmpty) 'rules': rules,
  });
  final Map<String, Object?> hostSeatAssigned = await hostClient.next();
  final Map<String, Object?> hostRoomFrame = await hostClient.next();
  final Map<String, Object?> hostSeatData =
      hostSeatAssigned['d']! as Map<String, Object?>;
  final Map<String, Object?> hostRoomData =
      hostRoomFrame['d']! as Map<String, Object?>;
  final String code = hostRoomData['code']! as String;

  final WireTestClient guestClient = await WireTestClient.connect(uri);
  clients.add(guestClient);
  guestClient.send('join_room', <String, Object?>{
    'code': code,
    'name': guestName,
  });
  final Map<String, Object?> guestSeatAssigned = await guestClient.next();
  final Map<String, Object?> guestRoomFrame = await guestClient.next();
  final Map<String, Object?> guestSeatData =
      guestSeatAssigned['d']! as Map<String, Object?>;

  // The host's socket also receives player_joined for the guest; drained
  // here so later reads on the host's queue see only what a later message
  // actually produces.
  await hostClient.next();

  return WireTestLobby(
    code: code,
    host: WireTestSeat(
      client: hostClient,
      seat: hostSeatData['seat']! as int,
      token: hostSeatData['seat_token']! as String,
    ),
    guest: WireTestSeat(
      client: guestClient,
      seat: guestSeatData['seat']! as int,
      token: guestSeatData['seat_token']! as String,
    ),
    hostRoom: hostRoomData,
    guestRoom: guestRoomFrame['d']! as Map<String, Object?>,
  );
}

/// Reads frames off [client] one at a time, discarding anything that is not
/// a [type] frame, up to [maxFrames]. Tolerates a correct implementation
/// interleaving other pushes in an order the spec does not pin, while still
/// failing -- inside a bounded, short wall-clock budget -- when the frame a
/// caller actually needs never shows up at all. Identical in behaviour to
/// the private helper of the same name in `fairness_lobby_test.dart`;
/// promoted here so more than one file can share it without a second
/// hand-copy drifting from the first.
Future<Map<String, Object?>> receiveType(
  WireTestClient client,
  String type, {
  int maxFrames = 6,
  Duration perFrame = const Duration(milliseconds: 500),
}) async {
  for (int i = 0; i < maxFrames; i++) {
    final Map<String, Object?> frame = await client.next(timeout: perFrame);
    if (frame['t'] == type) {
      return frame;
    }
  }
  throw TestFailure(
    'expected a "$type" frame within $maxFrames frames and none arrived',
  );
}

/// Reads frames off [client] one at a time until a [type] frame arrives,
/// returning every frame seen along the way, [type] included, in arrival
/// order. Tolerates any number of interleaved pushes while still failing,
/// inside a bounded, short wall-clock budget, when [type] never shows up at
/// all. Identical in behaviour to the private helper of the same name in
/// `fairness_lobby_test.dart`; promoted here for the same reason as
/// [receiveType] above.
Future<List<Map<String, Object?>>> drainUntil(
  WireTestClient client,
  String type, {
  int maxFrames = 6,
  Duration perFrame = const Duration(milliseconds: 500),
}) async {
  final List<Map<String, Object?>> frames = <Map<String, Object?>>[];
  for (int i = 0; i < maxFrames; i++) {
    final Map<String, Object?> frame = await client.next(timeout: perFrame);
    frames.add(frame);
    if (frame['t'] == type) {
      return frames;
    }
  }
  throw TestFailure(
    'expected a "$type" frame within $maxFrames frames on this socket and '
    'none arrived; frames seen along the way: $frames',
  );
}

// -----------------------------------------------------------------------
// Additive helper below this line, added for order 065 (`docs/PROTOCOL.md`
// section 13.1: a standalone `turn` follows `game_started`, always). Every
// call site that used to stop reading at `game_started` now has to consume
// this frame too, on every socket in the room, or it sits in that socket's
// queue and is mistaken for whatever the next helper actually asked for.
// -----------------------------------------------------------------------

/// Reads exactly one frame off [client] and asserts it is the standalone
/// `turn` frame section 13.1 requires immediately after `game_started`:
/// frame type `turn`, `d['seat'] == gameStartedTurn` (the `turn` field off
/// the `game_started` payload already read on this same socket) and
/// `d['deadline_ms']` a positive `int`. Reads with [WireTestClient.next]
/// rather than [receiveType] on purpose -- skipping past an out-of-order
/// frame here would hide the very defect this assertion exists to catch,
/// and section 13.1 promises this frame arrives with nothing between it
/// and `game_started` on a given socket. Does not check `seq`;
/// `test/turn_after_start_test.dart` (order 062) already owns the
/// `seq == game_started.seq + 1` rule and is the one place that changes if
/// that rule ever does.
Future<Map<String, Object?>> expectOpeningTurn(
  WireTestClient client,
  Object? gameStartedTurn,
) async {
  final Map<String, Object?> frame = await client.next();
  expect(
    frame['t'],
    'turn',
    reason: 'section 13.1: game_started must be immediately followed by a '
        'standalone turn frame on the same socket, with nothing between '
        'them; got a "${frame['t']}" frame instead: ${frame['d']}',
  );
  final Map<String, Object?> data = frame['d']! as Map<String, Object?>;
  expect(
    data['seat'],
    gameStartedTurn,
    reason: 'section 13.1: turn.seat must equal game_started.turn; got '
        'turn.seat=${data['seat']} game_started.turn=$gameStartedTurn',
  );
  final Object? rawDeadline = data['deadline_ms'];
  expect(
    rawDeadline,
    isA<int>(),
    reason: 'section 13.1: the opening turn frame must carry deadline_ms '
        'as an int -- the whole reason it exists, since game_started '
        'cannot carry it; got ${rawDeadline.runtimeType}: $rawDeadline',
  );
  expect(
    rawDeadline! as int,
    greaterThan(0),
    reason: 'deadline_ms on the opening turn frame must be a positive '
        'number of milliseconds remaining; got $rawDeadline',
  );
  return frame;
}

/// Asserts [frame] is an `error` frame carrying exactly [expectedCode].
/// [because] is folded into every assertion's failure message so a
/// mismatch names the scenario it was proving, not just the two codes that
/// disagreed.
void expectErrorFrame(
  Map<String, Object?> frame,
  String expectedCode, {
  required String because,
}) {
  if (frame['t'] != 'error') {
    throw TestFailure(
      'expected an error frame ($because) but got a "${frame['t']}" frame '
      'instead: ${frame['d']}',
    );
  }
  final Map<String, Object?> data = frame['d']! as Map<String, Object?>;
  if (data['code'] != expectedCode) {
    throw TestFailure(
      'expected error code $expectedCode ($because) but got '
      '${data['code']} (message: "${data['message']}")',
    );
  }
}
