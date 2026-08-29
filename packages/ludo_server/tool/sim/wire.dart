// A minimal, independent client-side speaker of docs/PROTOCOL.md section 1's
// envelope: `{ "v": 1, "t": <type>, "id": <id>, "d": <payload> }` out, the
// same shape plus an optional `re` in. Deliberately does not import anything
// from `package:ludo_server` or `test/support/wire_harness.dart`: this file
// is the simulator's own black-box view of the wire, built only from the
// protocol document, the same way a real client on a phone would be.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One decoded frame, either direction: the raw JSON object with string
/// keys, exactly as it went over the wire.
typedef Frame = Map<String, Object?>;

/// Reads [key] out of [frame]'s top-level envelope, requiring it be a
/// `String`. Used for `t` and `re`, which the envelope always types as
/// strings when present.
String frameType(Frame frame) => frame['t']! as String;

/// The `d` payload of [frame], as a typed map. Every server push and reply
/// carries one, per section 1: "Always present, possibly empty."
Map<String, Object?> frameData(Frame frame) {
  final Object? d = frame['d'];
  if (d is! Map<String, Object?>) {
    throw StateError('frame has no object "d": $frame');
  }
  return d;
}

/// Thrown by the small helpers below when a frame does not have the shape a
/// caller required. Carries enough of the offending frame to reproduce the
/// failure without having to re-run the scenario with logging turned up.
class UnexpectedFrame implements Exception {
  UnexpectedFrame(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Asserts [frame] is type [expectedType]. [because] names what step of the
/// scenario was expecting it, so a failure says what was expected, what
/// arrived, and where. If [frame] is an `error` frame the code and message
/// are folded into the failure text, since that is almost always the useful
/// part of an unexpected-frame failure.
void expectFrameType(Frame frame, String expectedType,
    {required String because}) {
  final String actual = frameType(frame);
  if (actual == expectedType) {
    return;
  }
  if (actual == 'error') {
    final Map<String, Object?> d = frameData(frame);
    throw UnexpectedFrame(
      'expected a "$expectedType" frame ($because) but got error '
      '${d['code']}: ${d['message']}',
    );
  }
  throw UnexpectedFrame(
    'expected a "$expectedType" frame ($because) but got "$actual": '
    '${frameData(frame)}',
  );
}

/// One live WebSocket connection to the server under test. Frames are
/// queued in arrival order from the instant the socket connects, whether or
/// not anything is waiting for one yet -- a server push a caller has not
/// asked for yet is buffered, never dropped, exactly the guarantee a real
/// client's own socket layer would give an app built on top of it.
class SimSocket {
  SimSocket._(this._socket, this.label);

  final WebSocket _socket;

  /// A short label identifying this socket's role in a scenario for
  /// diagnostics and for the `id` it mints, e.g. "host", "guest-2",
  /// "seat-1-reconnect-1". Kept to `[A-Za-z0-9-]` so every id built from it
  /// stays inside the 8-to-64-character `[A-Za-z0-9_-]` shape section 1
  /// requires.
  final String label;

  /// Every frame received on this socket, in arrival order, kept for the
  /// lifetime of the socket. Nothing is ever removed from this list; [next]
  /// consumes from a separate queue built on top of the same stream.
  final List<Frame> log = <Frame>[];

  final List<Frame> _buffered = <Frame>[];
  final List<Completer<Frame>> _waiting = <Completer<Frame>>[];
  bool _closed = false;
  int _idCounter = 0;

  /// Connects to [uri] exactly as given -- no path is appended, per the
  /// work order, because docs/PROTOCOL.md does not specify one beyond what
  /// the server's own routing already accepts at its root.
  static Future<SimSocket> connect(Uri uri, {required String label}) async {
    final WebSocket socket = await WebSocket.connect(uri.toString());
    final SimSocket sim = SimSocket._(socket, label);
    sim._listen();
    return sim;
  }

  void _listen() {
    _socket.listen(
      (Object? raw) {
        if (raw == null) {
          return;
        }
        final Object? decoded = jsonDecode(raw as String);
        if (decoded is! Map<String, Object?>) {
          throw StateError('[$label] non-object frame received: $raw');
        }
        final Frame frame = decoded;
        log.add(frame);
        if (_waiting.isNotEmpty) {
          _waiting.removeAt(0).complete(frame);
        } else {
          _buffered.add(frame);
        }
      },
      onDone: () {
        _closed = true;
        for (final Completer<Frame> completer in _waiting) {
          completer.completeError(
            StateError('[$label] socket closed before a frame arrived'),
          );
        }
        _waiting.clear();
      },
      onError: (Object error, StackTrace stackTrace) {
        for (final Completer<Frame> completer in _waiting) {
          completer.completeError(error, stackTrace);
        }
        _waiting.clear();
      },
      cancelOnError: false,
    );
  }

  /// The floor on the gap between two sends on the same socket:
  /// docs/PROTOCOL.md section 7 rate-limits "any message: 30 per second,
  /// then RATE_LIMITED, then close at 60" per connection. A human on a
  /// phone never comes close to that; this simulator can, because a seat
  /// that chains several capture bonuses (docs/RULES.md rule 10, "a capture
  /// on the last legal move grants an extra roll") gets many consecutive
  /// turns with nothing pacing them but the network round trip, which on a
  /// loopback target is near zero. 50ms caps a socket at 20 sends/second,
  /// comfortably under the limit, and only ever delays a socket that is
  /// actually sending back-to-back -- ordinary turns, with a real round
  /// trip to wait for a reply in between, never hit it.
  static const Duration _minSendInterval = Duration(milliseconds: 50);

  DateTime? _lastSendAt;

  /// Sends one client-to-server frame and returns the `id` it was sent
  /// with. Ids are a deterministic per-socket counter prefixed with this
  /// socket's [label], not random, so a failure that names an id is
  /// reproducible by re-running the same scenario against the same target.
  /// May wait briefly first; see [_minSendInterval].
  Future<String> send(String type, Map<String, Object?> data,
      {String? id}) async {
    final DateTime? lastSendAt = _lastSendAt;
    if (lastSendAt != null) {
      final Duration sinceLastSend = DateTime.now().difference(lastSendAt);
      if (sinceLastSend < _minSendInterval) {
        await Future<void>.delayed(_minSendInterval - sinceLastSend);
      }
    }
    _lastSendAt = DateTime.now();
    final String messageId = id ?? 'sim-$label-${++_idCounter}';
    _socket.add(jsonEncode(<String, Object?>{
      'v': 1,
      't': type,
      'id': messageId,
      'd': data,
    }));
    return messageId;
  }

  /// The next frame this socket receives, in arrival order. Bounded by
  /// [timeout] so a frame the server never sends fails the scenario
  /// promptly, with a message naming this socket's label, rather than
  /// hanging until the run's overall `--timeout-seconds` budget expires
  /// with no indication of which socket stalled.
  Future<Frame> next({Duration timeout = const Duration(seconds: 20)}) {
    if (_buffered.isNotEmpty) {
      return Future<Frame>.value(_buffered.removeAt(0));
    }
    if (_closed) {
      return Future<Frame>.error(
        StateError('[$label] socket already closed and no frame was pending'),
      );
    }
    final Completer<Frame> completer = Completer<Frame>();
    _waiting.add(completer);
    return completer.future.timeout(
      timeout,
      onTimeout: () => throw TimeoutException(
        '[$label] expected another frame within $timeout and none arrived',
      ),
    );
  }

  Future<void> close() async {
    if (_socket.readyState == WebSocket.open) {
      await _socket.close();
    }
  }
}
