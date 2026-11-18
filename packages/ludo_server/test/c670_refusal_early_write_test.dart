// Pins `docs/PROTOCOL.md` section 27 for a phone that writes at once: an app
// below the server minimum that sends its first frame (`create_room`,
// `join_room` or `resume`) the moment the socket opens must still be told to
// update, every time, through a reverse proxy that adds latency (C-670 C1);
// the refusal itself stays what section 27 says (C-670 C2).
//
// Written from the C-670 contract, not from a reading of any implementation.
//
// The server under test is a real `WireServer` with the gate at 576, as
// `c634_client_build_test.dart` runs it. Between it and the client sits an
// in-test TCP relay that delays every byte, in each direction, by a fixed
// number of milliseconds and can hand the bytes on one at a time. The client
// is a real `dart:io` WebSocket that writes a valid `join_room` frame in the
// same turn it learns the upgrade succeeded. A second client speaks the
// WebSocket bytes itself, so it can write its frame in a segment of its own
// straight behind the upgrade request and can read a close frame and say
// nothing back. One relay shape closes the client leg the moment the server
// ends, the way a busy reverse proxy does. Nothing here is mocked.
//
// Reproducing a failure: nothing is random. Every failure message names the
// scenario (build header, relay delay, whether the relay splits writes),
// how many of the connections failed, the close codes seen and the first few
// outcomes in full. Re-run one scenario with
// `dart test test/c670_refusal_early_write_test.dart -n '<test name>'`.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

/// The minimum build the server runs with in every case here.
const int _minBuild = 576;

/// The header as the app spells it on the wire.
const String _header = 'Ludo-Client-Build';

/// How long any single wait on a real socket may take before the case is
/// called failed. A liveness bound on a condition, never a pause.
const Duration _bound = Duration(seconds: 5);

/// C2: the longest a refused socket may stay up after the refusal.
const Duration _goneWithin = Duration(seconds: 2);

/// How many connections each build opens in a scenario.
const int _connections = 30;

// ---------------------------------------------------------------------------
// A TCP relay that adds latency.
// ---------------------------------------------------------------------------

/// How the relay treats the bytes it carries.
class _Link {
  const _Link({
    required this.delay,
    this.backDelay,
    this.singleBytes = false,
    this.proxyLike = false,
  });

  /// Added to every chunk, every end-of-stream and every reset travelling
  /// from the client to the server.
  final Duration delay;

  /// The same for the server to client direction; [delay] when null.
  final Duration? backDelay;

  /// Write each chunk on one byte at a time, flushing between bytes.
  final bool singleBytes;

  /// Behave like a busy reverse proxy: once the server side has ended, act on
  /// it 5 ms late and close the client leg outright instead of waiting for the
  /// client to end its own half, and after the client's upgrade request stop
  /// reading the client for 100 ms, so a frame the phone writes straight after
  /// the upgrade waits unread in the proxy's kernel buffer when it closes.
  final bool proxyLike;

  Duration get _closeLag =>
      proxyLike ? const Duration(milliseconds: 5) : Duration.zero;

  Duration get _holdClient =>
      proxyLike ? const Duration(milliseconds: 100) : Duration.zero;

  String get label => '${delay.inMilliseconds}ms'
      '${backDelay == null ? '' : ' out / ${backDelay!.inMilliseconds}ms back'}'
      '${singleBytes ? ' single-byte writes' : ''}'
      '${proxyLike ? ' proxy-like close' : ''}';
}

enum _Kind { data, end, reset }

class _Item {
  _Item(this.kind, this.due, [this.bytes]);

  final _Kind kind;
  final DateTime due;
  final List<int>? bytes;
}

/// One direction of one relayed connection: everything read from [from] is
/// written to [to] after the link delay, in order, with the end of stream
/// and any reset delayed the same way, so a reset can never overtake data.
class _Pipe {
  _Pipe(
    this.from,
    this.to,
    this.link,
    this.delay,
    this.onFinished, {
    Duration pauseAfterFirst = Duration.zero,
    Duration closeLag = Duration.zero,
  }) {
    to.done.then<void>((Object? _) {}, onError: (Object _) {});
    bool first = true;
    late final StreamSubscription<Uint8List> sub;
    void listen() => sub = from.listen(
          (Uint8List chunk) {
            _enqueue(_Item(_Kind.data, _due(), List<int>.of(chunk)));
            if (first && pauseAfterFirst > Duration.zero) {
              sub.pause();
              Timer(pauseAfterFirst, sub.resume);
            }
            first = false;
          },
          onDone: () => _enqueue(_Item(_Kind.end, _due().add(closeLag))),
          onError: (Object error) => _enqueue(_Item(_Kind.reset, _due())),
          cancelOnError: true,
        );
    listen();
  }

  final Socket from;
  final Socket to;
  final _Link link;
  final Duration delay;
  final void Function(bool reset) onFinished;
  final List<_Item> _queue = <_Item>[];
  bool _pumping = false;

  DateTime _due() => DateTime.now().add(delay);

  void _enqueue(_Item item) {
    _queue.add(item);
    if (!_pumping) {
      unawaited(_pump());
    }
  }

  Future<void> _pump() async {
    _pumping = true;
    while (_queue.isNotEmpty) {
      final _Item item = _queue.removeAt(0);
      final Duration wait = item.due.difference(DateTime.now());
      if (wait > Duration.zero) {
        await Future<void>.delayed(wait);
      }
      try {
        switch (item.kind) {
          case _Kind.data:
            if (link.singleBytes) {
              for (final int byte in item.bytes!) {
                to.add(<int>[byte]);
                await to.flush();
              }
            } else {
              to.add(item.bytes!);
              await to.flush();
            }
          case _Kind.end:
            await to.close();
            onFinished(false);
          case _Kind.reset:
            to.destroy();
            onFinished(true);
        }
      } on Object {
        // The far side is already gone; the relay has nothing left to tell it.
      }
    }
    _pumping = false;
  }
}

/// A listening relay in front of one upstream port.
class _Relay {
  _Relay._(this._listener, this.upstreamPort, this.link) {
    _listener.listen(_accept);
  }

  static Future<_Relay> start(int upstreamPort, _Link link) async {
    final ServerSocket listener = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    return _Relay._(listener, upstreamPort, link);
  }

  final ServerSocket _listener;
  final int upstreamPort;
  final _Link link;
  final List<Socket> _sockets = <Socket>[];

  int get port => _listener.port;

  /// How many connections the server side reset, as far as the relay saw.
  int upstreamResets = 0;

  Future<void> _accept(Socket client) async {
    _sockets.add(client);
    client.setOption(SocketOption.tcpNoDelay, true);
    final Socket upstream;
    try {
      upstream = await Socket.connect(
        InternetAddress.loopbackIPv4,
        upstreamPort,
      );
    } on Object {
      client.destroy();
      return;
    }
    upstream.setOption(SocketOption.tcpNoDelay, true);
    _sockets.add(upstream);
    int finished = 0;
    void finish(bool reset) {
      finished++;
      if (reset || finished == 2) {
        client.destroy();
        upstream.destroy();
      }
    }

    _Pipe(
      client,
      upstream,
      link,
      link.delay,
      finish,
      pauseAfterFirst: link._holdClient,
    );
    _Pipe(
      upstream,
      client,
      link,
      link.backDelay ?? link.delay,
      (bool reset) {
        if (reset) {
          upstreamResets++;
        }
        finish(reset || link.proxyLike);
      },
      closeLag: link._closeLag,
    );
  }

  Future<void> close() async {
    await _listener.close();
    for (final Socket s in _sockets) {
      s.destroy();
    }
  }
}

// ---------------------------------------------------------------------------
// The server fixture.
// ---------------------------------------------------------------------------

/// One running gated server, and the registry and rate limiter behind it.
class _Fixture {
  _Fixture(this.scenario) {
    clock = FakeClock(DateTime.utc(2026, 11, 18));
    registry = RoomRegistry(clock: clock, secure: Random.secure());
    rateLimiter = RateLimiter(clock: clock);
    server = WireServer(
      registry: registry,
      rateLimiter: rateLimiter,
      clock: clock,
      automaticTurnExpiry: false,
      minClientBuild: _minBuild,
    );
  }

  final String scenario;
  late final FakeClock clock;
  late final RoomRegistry registry;
  late final RateLimiter rateLimiter;
  late final WireServer server;
  final List<String> lines = <String>[];
  final List<_Relay> relays = <_Relay>[];
  final List<Socket> sockets = <Socket>[];
  final List<WebSocket> webSockets = <WebSocket>[];

  Future<void> start() =>
      server.start(address: InternetAddress.loopbackIPv4, port: 0);

  Future<_Relay> relay(_Link link) async {
    final _Relay r = await _Relay.start(server.port, link);
    relays.add(r);
    return r;
  }

  String get context => 'scenario="$scenario", server minClientBuild='
      '$_minBuild, rooms=${registry.roomCount}';

  Never fail(String message) => throw TestFailure('$message ($context)');

  Future<void> close() async {
    for (final WebSocket w in webSockets) {
      await w.close().timeout(const Duration(seconds: 1), onTimeout: () {});
    }
    for (final Socket s in sockets) {
      s.destroy();
    }
    for (final _Relay r in relays) {
      await r.close();
    }
    await server.close();
  }
}

/// Runs [body] against a fresh [_Fixture] started inside a `Zone` that keeps
/// every line the server prints, so a failure can show them. Always closes
/// the server.
Future<void> _scenario(
  String scenario,
  Future<void> Function(_Fixture f) body,
) async {
  late _Fixture fixture;
  Object? failure;
  StackTrace? failureStack;
  await runZoned(
    () async {
      fixture = _Fixture(scenario);
      await fixture.start();
      try {
        await body(fixture);
      } on Object catch (error, stack) {
        failure = error;
        failureStack = stack;
      } finally {
        await fixture.close();
      }
    },
    zoneSpecification: ZoneSpecification(
      print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
        fixture.lines.add(line);
      },
    ),
  );
  if (failure != null) {
    Error.throwWithStackTrace(failure!, failureStack!);
  }
}

/// A well-formed `join_room` envelope as the text the wire carries.
String _joinFrame(String id, {String code = 'ABCDEF', int pad = 0}) =>
    jsonEncode(
      <String, Object?>{
        'v': 1,
        't': 'join_room',
        'id': id,
        'd': <String, Object?>{
          'code': code,
          'name': 'Early',
          if (pad > 0) 'pad': 'x' * pad,
        },
      },
    );

String _envelope(String id, String type, Map<String, Object?> data) =>
    jsonEncode(<String, Object?>{'v': 1, 't': type, 'id': id, 'd': data});

// ---------------------------------------------------------------------------
// C1: the early writer.
// ---------------------------------------------------------------------------

/// What one early-writing connection saw.
class _Outcome {
  _Outcome(this.index, this.header);

  final int index;
  final String? header;
  final List<Object?> frames = <Object?>[];
  int? closeCode;
  String? closeReason;
  String? connectError;
  bool stillOpen = false;

  /// Null when the connection got what C1 demands, else why not.
  String? get problem {
    if (connectError != null) {
      return 'the upgrade itself failed: $connectError';
    }
    if (frames.isEmpty) {
      return 'no frame at all (close code $closeCode'
          '${stillOpen ? ', socket still open after $_bound' : ''})';
    }
    final Object? first = frames.first;
    if (first is! Map<String, Object?> ||
        first['t'] != 'error' ||
        first['d'] is! Map<String, Object?>) {
      return 'first frame is not an error frame: $first';
    }
    final Map<String, Object?> d = first['d']! as Map<String, Object?>;
    if (d['code'] != 'UPDATE_REQUIRED') {
      return 'first frame carries code ${d['code']}, not UPDATE_REQUIRED';
    }
    if (d['min_build'] != _minBuild) {
      return 'min_build is ${d['min_build']}, not $_minBuild';
    }
    if (stillOpen) {
      return 'frame arrived but the socket was not closed within $_bound';
    }
    if (closeCode != 4005) {
      return 'frame arrived but close code is $closeCode, not 4005';
    }
    return null;
  }

  String get label => 'conn#$index header=${header ?? 'none'}';

  @override
  String toString() => '$label frames=$frames closeCode=$closeCode '
      'closeReason=$closeReason problem=$problem';
}

/// Opens one WebSocket to [port] with [header] as the build header (none when
/// null), writes a valid `join_room` frame in the same turn the upgrade
/// completes, then reads until the socket closes.
Future<_Outcome> _earlyWriter(
  _Fixture f,
  int port,
  String? header,
  int index, {
  int frames = 1,
  int pad = 0,
}) async {
  final _Outcome out = _Outcome(index, header);
  final WebSocket socket;
  try {
    socket = await WebSocket.connect(
      'ws://127.0.0.1:$port/',
      headers: <String, String>{if (header != null) _header: header},
    ).timeout(_bound);
  } on Object catch (error) {
    out.connectError = '$error';
    return out;
  }
  f.webSockets.add(socket);
  final Completer<void> done = Completer<void>();
  socket.listen(
    (Object? raw) {
      try {
        out.frames.add(jsonDecode(raw! as String));
      } on Object {
        out.frames.add('undecodable: $raw');
      }
    },
    onDone: () {
      if (!done.isCompleted) {
        done.complete();
      }
    },
    onError: (Object error) {
      if (!done.isCompleted) {
        done.complete();
      }
    },
  );
  for (int n = 0; n < frames; n++) {
    socket.add(
      _joinFrame(
        'c670-early-${index.toString().padLeft(3, '0')}-$n',
        pad: pad,
      ),
    );
  }
  try {
    await done.future.timeout(_bound);
  } on TimeoutException {
    out.stillOpen = true;
  }
  out.closeCode = socket.closeCode;
  out.closeReason = socket.closeReason;
  return out;
}

/// The same early write as [_earlyWriter] from a client that speaks the bytes
/// itself. With [pipelined] the frame goes out in the same turn as the
/// upgrade request, before any answer; otherwise it waits for the 101. It
/// never answers a close, and is done once it has the close frame or the
/// server has dropped it.
Future<_Outcome> _rawEarlyWriter(
  _Fixture f,
  int port,
  String? header,
  int index, {
  required bool pipelined,
}) async {
  final _Outcome out = _Outcome(index, header);
  final _RawWs ws = await _RawWs.open(f, port, header, 'raw-$index');
  final String frame = _joinFrame(
    'c670-raw-${index.toString().padLeft(3, '0')}',
  );
  if (pipelined) {
    // Its own TCP segment, straight behind the request.
    await ws.socket.flush();
    ws.sendText(frame);
  } else {
    await ws.until(() => ws.upgraded || ws.isGone, 'the 101 answer', f);
    ws.sendText(frame);
  }
  try {
    await ws.until(
      () => ws.closeFrameAt != null || ws.isGone,
      'the close frame',
      f,
    );
  } on TestFailure {
    out.stillOpen = true;
  }
  for (final _RawFrame fr in ws.frames) {
    if (fr.isClose) {
      out.closeCode ??= fr.closeCode;
    } else {
      out.frames.add(jsonDecode(fr.text));
    }
  }
  return out;
}

/// Opens [_connections] early writers for each header in [headers], one after
/// another, through a relay with [link] in front of the server, and fails
/// with the full tally when any of them did not get the C1 refusal.
Future<void> _expectEveryConnectionRefused(
  String scenario,
  _Link link,
  List<String?> headers, {
  int frames = 1,
  int pad = 0,
  bool raw = false,
  bool pipelined = false,
}) async {
  await _scenario(scenario, (_Fixture f) async {
    final _Relay relay = await f.relay(link);
    for (final String? header in headers) {
      final List<_Outcome> outcomes = <_Outcome>[];
      for (int i = 0; i < _connections; i++) {
        outcomes.add(
          raw
              ? await _rawEarlyWriter(
                  f,
                  relay.port,
                  header,
                  i,
                  pipelined: pipelined,
                )
              : await _earlyWriter(
                  f,
                  relay.port,
                  header,
                  i,
                  frames: frames,
                  pad: pad,
                ),
        );
      }
      final List<_Outcome> lost =
          outcomes.where((_Outcome o) => o.problem != null).toList();
      if (lost.isNotEmpty) {
        final Map<String, int> codes = <String, int>{};
        for (final _Outcome o in outcomes) {
          final String key = '${o.closeCode}'
              '${o.frames.isEmpty ? ' (no frame)' : ''}'
              '${o.stillOpen ? ' (still open)' : ''}';
          codes[key] = (codes[key] ?? 0) + 1;
        }
        f.fail(
          'C1: every early-writing client below build $_minBuild must get the '
          'UPDATE_REQUIRED error frame (min_build $_minBuild) and then close '
          '4005. Header ${header ?? 'none'} through a relay adding '
          '${link.label} each way: ${lost.length} of $_connections '
          'connections lost the refusal. Close codes seen across all '
          '$_connections (code, frame or not): $codes. Server resets seen by the '
          'relay: ${relay.upstreamResets}. First failures: '
          '${lost.take(3).map((_Outcome o) => '$o').join(' | ')}',
        );
      }
    }
  });
}

// ---------------------------------------------------------------------------
// C2: a raw client that speaks the WebSocket bytes itself.
// ---------------------------------------------------------------------------

/// One decoded server frame.
class _RawFrame {
  _RawFrame(this.opcode, this.payload);

  final int opcode;
  final List<int> payload;

  bool get isClose => opcode == 8;
  String get text => utf8.decode(payload, allowMalformed: true);

  int? get closeCode =>
      isClose && payload.length >= 2 ? (payload[0] << 8) | payload[1] : null;

  @override
  String toString() => isClose ? 'close($closeCode)' : 'frame($text)';
}

/// A bare TCP client that performs the upgrade by hand and decodes server
/// frames, so it can read a close frame and then say nothing back, which a
/// library WebSocket never does.
class _RawWs {
  _RawWs._(this.socket, this.label) {
    socket.done.then<void>((Object? _) {}, onError: (Object _) {});
    socket.listen(
      _onData,
      onDone: _finish,
      onError: (Object error) {
        resetSeen = true;
        _finish();
      },
      cancelOnError: true,
    );
  }

  static Future<_RawWs> open(
    _Fixture f,
    int port,
    String? header,
    String label,
  ) async {
    final Socket socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
    ).timeout(_bound);
    socket.setOption(SocketOption.tcpNoDelay, true);
    f.sockets.add(socket);
    final _RawWs ws = _RawWs._(socket, label);
    socket.add(
      ascii.encode(
        'GET / HTTP/1.1\r\n'
        'Host: 127.0.0.1:$port\r\n'
        'Connection: Upgrade\r\n'
        'Upgrade: websocket\r\n'
        'Sec-WebSocket-Version: 13\r\n'
        'Sec-WebSocket-Key: ${base64Encode(List<int>.generate(16, (int i) => i))}\r\n'
        '${header == null ? '' : '$_header: $header\r\n'}'
        '\r\n',
      ),
    );
    return ws;
  }

  final Socket socket;
  final String label;
  final List<int> _buffer = <int>[];
  final List<_RawFrame> frames = <_RawFrame>[];
  final Completer<void> _gone = Completer<void>();
  final List<Completer<void>> _waiters = <Completer<void>>[];
  bool upgraded = false;
  bool resetSeen = false;
  final Stopwatch clock = Stopwatch()..start();
  Duration? firstFrameAt;
  Duration? closeFrameAt;
  Duration? goneAt;

  bool get isGone => _gone.isCompleted;
  Future<void> get gone => _gone.future;

  void _finish() {
    goneAt ??= clock.elapsed;
    if (!_gone.isCompleted) {
      _gone.complete();
    }
    _wake();
  }

  void _wake() {
    final List<Completer<void>> waiting = List<Completer<void>>.of(_waiters);
    _waiters.clear();
    for (final Completer<void> w in waiting) {
      if (!w.isCompleted) {
        w.complete();
      }
    }
  }

  void _onData(List<int> chunk) {
    _buffer.addAll(chunk);
    if (!upgraded) {
      final int end = _indexOfHeadEnd();
      if (end < 0) {
        return;
      }
      upgraded = true;
      _buffer.removeRange(0, end);
    }
    while (true) {
      if (_buffer.length < 2) {
        break;
      }
      final int opcode = _buffer[0] & 0x0f;
      int length = _buffer[1] & 0x7f;
      int offset = 2;
      if (length == 126) {
        if (_buffer.length < 4) {
          break;
        }
        length = (_buffer[2] << 8) | _buffer[3];
        offset = 4;
      } else if (length == 127) {
        if (_buffer.length < 10) {
          break;
        }
        length = 0;
        for (int i = 2; i < 10; i++) {
          length = (length << 8) | _buffer[i];
        }
        offset = 10;
      }
      if (_buffer.length < offset + length) {
        break;
      }
      final _RawFrame frame = _RawFrame(
        opcode,
        _buffer.sublist(offset, offset + length),
      );
      _buffer.removeRange(0, offset + length);
      frames.add(frame);
      firstFrameAt ??= clock.elapsed;
      if (frame.isClose) {
        closeFrameAt ??= clock.elapsed;
      }
    }
    _wake();
  }

  int _indexOfHeadEnd() {
    for (int i = 0; i + 3 < _buffer.length; i++) {
      if (_buffer[i] == 13 &&
          _buffer[i + 1] == 10 &&
          _buffer[i + 2] == 13 &&
          _buffer[i + 3] == 10) {
        return i + 4;
      }
    }
    return -1;
  }

  /// Sends one masked text frame. A socket that is already gone swallows it.
  void sendText(String text) {
    final List<int> payload = utf8.encode(text);
    final List<int> mask = <int>[0x11, 0x22, 0x33, 0x44];
    final List<int> out = <int>[0x81];
    if (payload.length < 126) {
      out.add(0x80 | payload.length);
    } else {
      out
        ..add(0x80 | 126)
        ..add(payload.length >> 8)
        ..add(payload.length & 0xff);
    }
    out.addAll(mask);
    for (int i = 0; i < payload.length; i++) {
      out.add(payload[i] ^ mask[i % 4]);
    }
    try {
      socket.add(out);
    } on Object {
      // Closed under us: nothing more to deliver.
    }
  }

  /// Waits until [condition] holds, or fails after [_bound].
  Future<void> until(
    bool Function() condition,
    String what,
    _Fixture f,
  ) async {
    final DateTime deadline = DateTime.now().add(_bound);
    while (!condition()) {
      final Duration left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) {
        f.fail(
          'expected $what on raw socket "$label" within $_bound and it never '
          'held; frames so far: $frames, gone=$isGone',
        );
      }
      final Completer<void> waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future.timeout(left, onTimeout: () {});
    }
  }
}

// ---------------------------------------------------------------------------
// Waiting on the registry through the wire.
// ---------------------------------------------------------------------------

/// Reads frames from a library WebSocket the test drives as a good client.
class _Good {
  _Good._(this.socket) {
    socket.listen((Object? raw) {
      frames.add(jsonDecode(raw! as String) as Map<String, Object?>);
      _wake();
    });
  }

  static Future<_Good> dial(_Fixture f, int port) async {
    final WebSocket socket = await WebSocket.connect(
      'ws://127.0.0.1:$port/',
      headers: <String, String>{_header: '$_minBuild'},
    ).timeout(_bound);
    f.webSockets.add(socket);
    return _Good._(socket);
  }

  final WebSocket socket;
  final List<Map<String, Object?>> frames = <Map<String, Object?>>[];
  final List<Completer<void>> _waiters = <Completer<void>>[];
  int _ids = 0;

  void _wake() {
    final List<Completer<void>> waiting = List<Completer<void>>.of(_waiters);
    _waiters.clear();
    for (final Completer<void> w in waiting) {
      if (!w.isCompleted) {
        w.complete();
      }
    }
  }

  /// Sends [type] and returns the first `room` or `error` frame that answers.
  Future<Map<String, Object?>> ask(
    _Fixture f,
    String type,
    Map<String, Object?> data,
  ) async {
    final int seen = frames.length;
    socket.add(_envelope(
        'c670-good-${(++_ids).toString().padLeft(4, '0')}', type, data));
    final DateTime deadline = DateTime.now().add(_bound);
    while (true) {
      for (int i = seen; i < frames.length; i++) {
        if (frames[i]['t'] == 'room' || frames[i]['t'] == 'error') {
          return frames[i];
        }
      }
      final Duration left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) {
        f.fail('no answer to $type within $_bound; frames: $frames');
      }
      final Completer<void> waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future.timeout(left, onTimeout: () {});
    }
  }
}

void main() {
  // The relay shapes C1 is run through. The first is the one the contract
  // names; the rest vary the latency and hand the bytes on one at a time.
  const List<_Link> links = <_Link>[
    _Link(delay: Duration(milliseconds: 30)),
    _Link(delay: Duration(milliseconds: 10)),
    _Link(delay: Duration(milliseconds: 60)),
    _Link(delay: Duration(milliseconds: 30), singleBytes: true),
    _Link(
      delay: Duration(milliseconds: 2),
      backDelay: Duration(milliseconds: 60),
    ),
    _Link(delay: Duration(milliseconds: 30), proxyLike: true),
  ];
  final List<_Link> shapes = <_Link>[links.first, links.last];

  group('C1: an early writer below the minimum is told to update', () {
    for (final _Link link in links) {
      test(
        'builds none and 575, $_connections connections each, one '
        '`join_room` written at once, relay ${link.label} each way',
        () async {
          await _expectEveryConnectionRefused(
            'C1 relay=${link.label} headers=none,575 '
            'connections=$_connections each, first frame join_room',
            link,
            <String?>[null, '575'],
          );
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );
    }

    for (final _Link link in shapes) {
      test('X burst: 40 frames of 4 KB, relay ${link.label}', () async {
        await _expectEveryConnectionRefused(
          'X burst relay=${link.label}',
          link,
          <String?>[null, '575'],
          frames: 40,
          pad: 4096,
        );
      }, timeout: const Timeout(Duration(minutes: 3)));
    }

    for (final _Link link in shapes) {
      for (final bool pipelined in <bool>[false, true]) {
        test(
          'raw client, first frame ${pipelined ? 'sent with the upgrade '
              'request' : 'sent on the 101'}, relay ${link.label}',
          () async {
            await _expectEveryConnectionRefused(
              'C1 raw pipelined=$pipelined relay=${link.label}',
              link,
              <String?>[null, '575'],
              raw: true,
              pipelined: pipelined,
            );
          },
          timeout: const Timeout(Duration(minutes: 3)),
        );
      }
    }

    test('no relay at all: the same early writer is refused', () async {
      await _scenario('C1 direct, no relay, headers=none,575', (
        _Fixture f,
      ) async {
        for (final String? header in <String?>[null, '575']) {
          for (int i = 0; i < _connections; i++) {
            final _Outcome o = await _earlyWriter(
              f,
              f.server.port,
              header,
              i,
            );
            if (o.problem != null) {
              f.fail(
                'C1: an early writer must be refused without any proxy in '
                'between. Got $o',
              );
            }
          }
        }
      });
    });

    test('a build at the minimum is not refused through the relay', () async {
      await _scenario('C1 control, build $_minBuild through relay 30ms', (
        _Fixture f,
      ) async {
        final _Relay relay = await f.relay(
          const _Link(delay: Duration(milliseconds: 30)),
        );
        final _Good good = await _Good.dial(f, relay.port);
        final Map<String, Object?> answer = await good.ask(
          f,
          'create_room',
          <String, Object?>{'name': 'Host', 'players': 2},
        );
        expect(
          answer['t'],
          'room',
          reason: 'a build at the minimum creates a room through the relay. '
              'Got $answer. ${f.context}',
        );
        expect(f.registry.roomCount, 1, reason: f.context);
      });
    });
  });

  group('C2: the refusal stays what section 27 says', () {
    test(
      'a client that reads the close and never answers it is disconnected '
      'within 2 s of the refusal',
      () async {
        await _scenario('C2 silent client, build 575, direct', (
          _Fixture f,
        ) async {
          final _RawWs ws = await _RawWs.open(
            f,
            f.server.port,
            '575',
            'silent-575',
          );
          ws.sendText(_joinFrame('c670-silent-0001'));
          await ws.until(
            () => ws.frames.isNotEmpty,
            'the UPDATE_REQUIRED frame',
            f,
          );
          final Duration refusedAt = ws.firstFrameAt!;
          final Map<String, Object?> first =
              jsonDecode(ws.frames.first.text) as Map<String, Object?>;
          expect(
            (first['d']! as Map<String, Object?>)['code'],
            'UPDATE_REQUIRED',
            reason: 'first frame must be the refusal. Got ${ws.frames}. '
                '${f.context}',
          );
          final bool goneInTime = await ws.gone
              .then((_) => true)
              .timeout(_goneWithin, onTimeout: () => false);
          expect(
            goneInTime,
            isTrue,
            reason:
                'C2: the client read the refusal at ${refusedAt.inMilliseconds}'
                ' ms and never answered the close. The server must drop the '
                'socket within ${_goneWithin.inMilliseconds} ms of the '
                'refusal; it was still up ${_goneWithin.inMilliseconds} ms '
                'after. Frames received: ${ws.frames}. ${f.context}',
          );
          expect(
            ws.frames.map((_RawFrame fr) => fr.closeCode).whereType<int>(),
            <int>[4005],
            reason: 'C2: close code 4005 is what the client was told. '
                'Frames received: ${ws.frames}. ${f.context}',
          );
          expect(
            ws.frames.where((_RawFrame fr) => !fr.isClose),
            hasLength(1),
            reason: 'C2: exactly one non-close frame, the refusal. Frames '
                'received: ${ws.frames}. ${f.context}',
          );
        });
      },
    );

    test(
      'a client that keeps writing after the close and never answers it is '
      'disconnected within 2 s of the refusal',
      () async {
        await _scenario('C2 chatty client, build none, direct', (
          _Fixture f,
        ) async {
          final _RawWs ws = await _RawWs.open(
            f,
            f.server.port,
            null,
            'chatty-none',
          );
          int sent = 0;
          void write() => ws.sendText(_envelope(
                'c670-chatty-${(++sent).toString().padLeft(4, '0')}',
                'create_room',
                <String, Object?>{'name': 'Late', 'players': 2},
              ));
          write();
          await ws.until(
            () => ws.frames.isNotEmpty,
            'the UPDATE_REQUIRED frame',
            f,
          );
          // The client carries on writing, as an app that has not yet read the
          // refusal would, every 50 ms until the server hangs up on it.
          final Timer chatter = Timer.periodic(
            const Duration(milliseconds: 50),
            (_) => write(),
          );
          final Duration refusedAt = ws.firstFrameAt!;
          final bool goneInTime = await ws.gone
              .then((_) => true)
              .timeout(_goneWithin, onTimeout: () => false);
          chatter.cancel();
          expect(
            goneInTime,
            isTrue,
            reason:
                'C2: the client read the refusal at ${refusedAt.inMilliseconds}'
                ' ms and kept writing without answering the close. The server '
                'must drop the socket within ${_goneWithin.inMilliseconds} ms '
                'of the refusal. Frames received: ${ws.frames}, frames '
                'written: $sent. ${f.context}',
          );
          expect(
            f.registry.roomCount,
            0,
            reason: 'C2: the writes made no room. ${f.context}',
          );
        });
      },
    );

    for (final _Link? link in <_Link?>[
      null,
      const _Link(delay: Duration(milliseconds: 30)),
    ]) {
      final String via = link == null ? 'direct' : 'relay ${link.label}';
      test(
        'a refused socket dispatches nothing: 6 create_room, 25 join_room '
        'and a join into a live room change no state ($via)',
        () async {
          await _scenario('C2 no dispatch, build 575, $via', (
            _Fixture f,
          ) async {
            final CreateResult made = f.registry.createRoom(
              name: 'Host',
              players: 2,
              rules: const RulesConfig(),
            );
            if (made is! CreateOk) {
              f.fail('the live room could not be made: $made');
            }
            final String live = made.room.code;
            final int port =
                link == null ? f.server.port : (await f.relay(link)).port;
            final _RawWs refused = await _RawWs.open(f, port, '575', via);
            for (int i = 0; i < 6; i++) {
              refused.sendText(_envelope(
                'c670-spam-c-${i.toString().padLeft(4, '0')}',
                'create_room',
                <String, Object?>{'name': 'Spam', 'players': 2},
              ));
            }
            for (int i = 0; i < 25; i++) {
              refused.sendText(_joinFrame(
                'c670-spam-j-${i.toString().padLeft(4, '0')}',
                code: live,
              ));
            }
            refused.sendText(_envelope(
              'c670-spam-r-0000',
              'resume',
              <String, Object?>{
                'code': live,
                'seat_token': made.seat.seatToken,
              },
            ));
            await refused.until(
              () => refused.frames.any((_RawFrame fr) => !fr.isClose),
              'the UPDATE_REQUIRED frame',
              f,
            );
            await refused.gone.timeout(
              _bound,
              onTimeout: () => f.fail(
                'the refused socket was never dropped within $_bound; '
                'frames: ${refused.frames}',
              ),
            );
            final List<_RawFrame> answers =
                refused.frames.where((_RawFrame fr) => !fr.isClose).toList();
            expect(
              answers,
              hasLength(1),
              reason: 'C2: a refused socket is answered once and only once '
                  '(the refusal). Frames: ${refused.frames}. ${f.context}',
            );
            expect(
              answers.single.text,
              contains('UPDATE_REQUIRED'),
              reason: 'C2: the one frame is the refusal. '
                  'Frames: ${refused.frames}. ${f.context}',
            );

            // A fresh accepted socket from the same address proves, through the
            // wire, that nothing the refused socket sent counted.
            final _Good good = await _Good.dial(f, port);
            String? firstCode;
            for (int i = 0; i < 5; i++) {
              final Map<String, Object?> answer = await good.ask(
                f,
                'create_room',
                <String, Object?>{'name': 'Host$i', 'players': 2},
              );
              if (answer['t'] != 'room') {
                f.fail(
                  'C2: create_room number ${i + 1} from a good socket was '
                  'answered with $answer; the refused socket must not use up '
                  'any of the 5 create_room attempts per hour for the '
                  'address.',
                );
              }
              firstCode ??=
                  (answer['d']! as Map<String, Object?>)['code'] as String?;
            }
            expect(
              f.registry.roomCount,
              6,
              reason: 'C2: only the live room and the good socket\'s five '
                  'rooms exist; a refused create_room made none. ${f.context}',
            );
            final Map<String, Object?> joined = await good.ask(
              f,
              'join_room',
              <String, Object?>{'code': firstCode, 'name': 'Joiner'},
            );
            expect(
              joined['t'],
              'room',
              reason: 'C2: the refused socket\'s 25 join_room frames used no '
                  'part of the 20 per minute join budget. Got $joined. '
                  '${f.context}',
            );
            expect(
              f.registry.lookup(live)!.seats,
              hasLength(1),
              reason: 'C2: the refused join_room seated nobody in the live '
                  'room and the refused resume took no seat over. '
                  '${f.context}',
            );
            expect(
              f.registry.lookup(live)!.seats.single.seatToken,
              made.seat.seatToken,
              reason: 'C2: the live room still holds its original seat. '
                  '${f.context}',
            );
          });
        },
      );
    }
  });
}
