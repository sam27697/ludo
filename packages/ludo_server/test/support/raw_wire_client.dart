// A WebSocket client with no envelope logic of its own, for the
// `docs/PROTOCOL.md` section 7 and 7.1 conformance cases that
// `test/support/wire_harness.dart`'s `WireTestClient` cannot drive, because
// that class always emits a well-formed `{v: 1, t: ..., id: ..., d: ...}`
// envelope and never exposes the underlying socket's close code.
//
// Specifically, this file exists for the cases that need:
//   - an arbitrary `v` or `t` value, not the fixed `v: 1` `WireTestClient`
//     always sends;
//   - a top-level JSON value that is not an object at all, or text that is
//     not JSON at all;
//   - a frame whose exact byte length on the wire is pinned to the number a
//     test wants, including one byte either side of the 8192-byte limit;
//   - a binary (not text) WebSocket frame;
//   - the close code the server actually sent, which `dart:io`'s own
//     `WebSocket.closeCode` carries once the connection has actually closed.
//
// Modelled on `client_ip_test.dart`'s own inline use of `dart:io`'s
// `WebSocket` directly, for the same reason that file gives: `ServerHarness`
// does not expose a client that can do this, so this dials the socket
// directly. Promoted to its own file because `protocol_conformance_test.dart`
// needs this shape of control in many cases, not one.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// One frame read off a [RawWireClient]'s socket, exactly as the transport
/// delivered it: [bytes] is set for a binary frame, [text] for a text frame.
/// [decoded] is the parsed JSON object when [text] was both valid JSON and a
/// JSON object; null otherwise, including for every binary frame, since a
/// test that wants to interpret binary bytes as text does so itself rather
/// than this class guessing an encoding on a caller's behalf.
class RawFrame {
  RawFrame({this.text, this.bytes, this.decoded});

  final String? text;
  final List<int>? bytes;
  final Map<String, Object?>? decoded;

  bool get isBinary => bytes != null;

  @override
  String toString() {
    if (isBinary) {
      return 'RawFrame(binary, ${bytes!.length} bytes)';
    }
    return 'RawFrame(text: $text)';
  }
}

/// Delivers decoded frames to whichever [RawWireClient.next] call is
/// waiting, in arrival order, buffering anything that arrives with nobody
/// waiting -- the same ordering guarantee `wire_harness.dart`'s own private
/// `_FrameQueue` gives `WireTestClient`, reimplemented here because that
/// class is private to its file and this one needs the same shape over a
/// socket that is not a `WireTestClient`.
class _RawFrameQueue {
  _RawFrameQueue(Stream<Object?> source) {
    _subscription = source.listen(
      (Object? raw) {
        final RawFrame frame = _decode(raw);
        if (_waiting.isNotEmpty) {
          _waiting.removeAt(0).complete(frame);
        } else {
          _buffered.add(frame);
        }
      },
      onDone: () {
        _closed = true;
        for (final Completer<RawFrame> completer in _waiting) {
          completer.completeError(
            StateError('socket closed before a frame arrived'),
          );
        }
        _waiting.clear();
        if (!_doneCompleter.isCompleted) {
          _doneCompleter.complete();
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        for (final Completer<RawFrame> completer in _waiting) {
          completer.completeError(error, stackTrace);
        }
        _waiting.clear();
      },
    );
  }

  late final StreamSubscription<Object?> _subscription;
  final List<RawFrame> _buffered = <RawFrame>[];
  final List<Completer<RawFrame>> _waiting = <Completer<RawFrame>>[];
  final Completer<void> _doneCompleter = Completer<void>();
  bool _closed = false;

  RawFrame _decode(Object? raw) {
    if (raw is List<int>) {
      return RawFrame(bytes: raw);
    }
    final String text = raw as String;
    try {
      final Object? parsed = jsonDecode(text);
      if (parsed is Map<String, Object?>) {
        return RawFrame(text: text, decoded: parsed);
      }
      return RawFrame(text: text);
    } on FormatException {
      return RawFrame(text: text);
    }
  }

  Future<RawFrame> next() {
    if (_buffered.isNotEmpty) {
      return Future<RawFrame>.value(_buffered.removeAt(0));
    }
    if (_closed) {
      return Future<RawFrame>.error(
        StateError('socket already closed and no frame was pending'),
      );
    }
    final Completer<RawFrame> completer = Completer<RawFrame>();
    _waiting.add(completer);
    return completer.future;
  }

  /// Resolves once the underlying stream has reported done, however that
  /// happened: a close the server initiated, a close this client initiated,
  /// or a transport failure. Already-complete if the stream was already
  /// done when this is called.
  Future<void> get done => _doneCompleter.future;

  Future<void> close() => _subscription.cancel();
}

/// A WebSocket client with no envelope logic of its own: every byte that
/// leaves it is exactly what a caller built, text or binary. See this file's
/// header for why `wire_harness.dart`'s `WireTestClient` cannot be used for
/// the cases that need this instead.
class RawWireClient {
  RawWireClient._(this._socket, this._queue);

  final WebSocket _socket;
  final _RawFrameQueue _queue;

  static Future<RawWireClient> connect(Uri uri) async {
    final WebSocket socket = await WebSocket.connect(uri.toString());
    return RawWireClient._(socket, _RawFrameQueue(socket));
  }

  /// Sends [text] on the wire as a single WebSocket text frame, completely
  /// unvalidated -- a caller builds the exact bytes it wants to test with.
  void sendText(String text) => _socket.add(text);

  /// Sends [bytes] on the wire as a single WebSocket binary frame.
  void sendBytes(List<int> bytes) => _socket.add(bytes);

  /// The next frame this socket receives, decoded per [RawFrame]. Bounded by
  /// [timeout] so a frame the server never sends fails the test promptly
  /// rather than hanging the suite.
  Future<RawFrame> next({Duration timeout = const Duration(seconds: 3)}) {
    return _queue.next().timeout(
          timeout,
          onTimeout: () => throw TestFailure(
            'expected another frame on this raw socket within $timeout and '
            'none arrived',
          ),
        );
  }

  /// Waits, bounded by [timeout], for this socket to actually close --
  /// whichever side initiated it -- then returns `dart:io`'s own
  /// [WebSocket.closeCode] for it. Unlike the server's own close path
  /// (`lib/src/connection.dart`'s long comment on `Connection.close`
  /// explains why that side can never observe its own close succeeding),
  /// this is the client end of a real socket receiving a real close frame
  /// over the wire, which `dart:io` does report.
  Future<int?> waitClosed(
      {Duration timeout = const Duration(seconds: 3)}) async {
    if (!_queue._closed) {
      try {
        await _queue.done.timeout(timeout);
      } on TimeoutException {
        throw TestFailure(
          'expected this raw socket to be closed by the server within '
          '$timeout and it was still open',
        );
      }
    }
    return _socket.closeCode;
  }

  /// `dart:io`'s own [WebSocket.closeCode] for this socket right now,
  /// without waiting for anything: null before any close has happened, and
  /// still null if the connection was simply abandoned (no close frame of
  /// any kind). Unlike [waitClosed], this never blocks and never fails a
  /// test for the answer being null -- a caller proving "nothing closes
  /// this" wants exactly that non-blocking read.
  int? get closeCode => _socket.closeCode;

  Future<void> close() async {
    await _queue.close();
    if (_socket.readyState == WebSocket.open) {
      await _socket.close();
    }
  }
}
