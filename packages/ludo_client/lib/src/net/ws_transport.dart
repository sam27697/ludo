// The one real implementation of [WireTransport], on top of
// `web_socket_channel`. Everything below `transport.dart` in the client is
// pure; this is the file that is allowed to know a socket exists.
//
// docs/PROTOCOL.md section 7.1 pins the close codes the server sends and
// notes that the Dart `web_socket` package underneath `web_socket_channel`
// rejects any close code outside 1000 or 3000-4999. A client closing
// deliberately has no reason to send anything but 1000, so 1000 is the only
// code this file ever passes down, and it is the default the interface
// already carries.

import 'dart:async';
import 'dart:io' show HttpClient;

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'transport.dart';

/// How often the socket this file opens pings the server, and how long it
/// then waits for the pong. docs/PROTOCOL.md section 24 rules 1 to 3: a link
/// that goes dead is closed from this side within twice this interval, with
/// no error frame first, which the controller treats as any other lost
/// connection.
const Duration kKeepaliveInterval = Duration(seconds: 10);

/// How long one attempt to open a socket (TCP, TLS and the HTTP upgrade
/// together) may take before it is abandoned. docs/PROTOCOL.md section 24
/// rule 4.
const Duration kConnectTimeout = Duration(seconds: 10);

/// Opens a [WsTransport] to [url] and completes once the socket is actually
/// connected.
///
/// Awaiting [WebSocketChannel.ready] before returning is the whole of the
/// contract in [TransportConnector]'s doc: a URL that cannot be reached
/// completes this future with an error, and a [WsTransport] is only ever
/// constructed once the handshake has actually succeeded, so there is no path
/// that hands the caller a transport that is quietly dead on arrival.
///
/// [pingInterval] is handed to the `dart:io` socket: it sends a ping every
/// interval, and a ping whose pong has not arrived within one interval closes
/// the socket with code 1001. That close reaches [WsTransport.done] like any
/// other end of the link.
///
/// [connectTimeout] bounds the attempt. `IOWebSocketChannel.connect` has a
/// `connectTimeout` of its own, but it is only `Future.timeout` on the
/// underlying `WebSocket.connect`: when it fires the connect carries on, a
/// socket that completes afterwards is never closed by anyone, and a connect
/// to a peer that never answers the upgrade keeps its TCP connection open
/// indefinitely. So the timeout is applied here instead, on a private
/// [HttpClient] that is force-closed when it fires. That tears down the
/// pending connection, and closing the sink first makes a socket that
/// completes in the same instant close itself as soon as it is wired up.
Future<WireTransport> connectWsTransport(
  Uri url, {
  Duration pingInterval = kKeepaliveInterval,
  Duration connectTimeout = kConnectTimeout,
}) async {
  final client = HttpClient();
  final IOWebSocketChannel channel;
  try {
    channel = IOWebSocketChannel.connect(
      url,
      pingInterval: pingInterval,
      customClient: client,
    );
  } catch (_) {
    client.close(force: true);
    rethrow;
  }
  try {
    await channel.ready.timeout(connectTimeout);
  } catch (_) {
    // Timed out or failed: nothing may stay open behind the error.
    unawaited(channel.sink.close().catchError((Object _) {}));
    client.close(force: true);
    rethrow;
  }
  // Connected. The socket was detached from the client, which has nothing
  // else to do.
  client.close();
  return WsTransport._(channel);
}

/// The real [WireTransport], backed by a [WebSocketChannel].
///
/// Binary frames: this protocol is text only (docs/PROTOCOL.md section 1),
/// and the server this client speaks to never sends one deliberately. A
/// binary frame arriving here is therefore always an anomaly in the
/// transport, not a payload the protocol engine above ever needs to see.
/// This class drops it: it is not added to [incoming], it does not close the
/// link, and it does not throw. The alternative -- surfacing it as an error
/// on [incoming], which the engine treats as equivalent to the link closing
/// -- would tear down a session over a frame the engine was never going to
/// read anyway. This is a genuine choice, not a forced one, and a reader who
/// wants the other behaviour should be able to find this comment.
class WsTransport implements WireTransport {
  WsTransport._(this._channel) {
    _subscription = _channel.stream.listen(
      _onData,
      onError: _onError,
      onDone: _onDone,
      cancelOnError: false,
    );
  }

  final WebSocketChannel _channel;
  late final StreamSubscription<dynamic> _subscription;

  final _incomingController = StreamController<String>();
  final _doneCompleter = Completer<void>();

  /// True once the link is gone, by any of the three paths in [done]'s doc.
  /// Guards every one of them so the second and third are no-ops.
  bool _finished = false;

  @override
  Stream<String> get incoming => _incomingController.stream;

  @override
  Future<void> get done => _doneCompleter.future;

  void _onData(Object? message) {
    if (_finished) return;
    if (message is String) {
      _incomingController.add(message);
    }
    // A List<int> (binary frame) is dropped; see the class doc.
  }

  void _onError(Object error, StackTrace stackTrace) {
    // WebSocketChannel.stream surfaces a mid-session failure as an error on
    // the stream rather than as a rejected sink.done. incoming's own doc
    // allows exactly this -- "it may also emit an error before closing" --
    // so the error is forwarded there, and the link is then finished exactly
    // as it would be for a clean close. done itself never carries it: done
    // is a plain "the link is gone", not a verdict on why.
    if (_finished) return;
    _incomingController.addError(error, stackTrace);
    _finish();
  }

  void _onDone() {
    if (_finished) return;
    _finish();
  }

  void _finish() {
    if (_finished) return;
    _finished = true;
    unawaited(_subscription.cancel());
    unawaited(_incomingController.close());
    _doneCompleter.complete();
  }

  @override
  void send(String text) {
    if (_finished) {
      return;
    }
    try {
      _channel.sink.add(text);
    } catch (_) {
      // The link died between the _finished check and this call, or the
      // sink was already closed underneath us. Either way the transport
      // never throws out of send; the caller learns the link is gone from
      // done, not from an exception at an arbitrary call site.
    }
  }

  @override
  Future<void> close([int code = 1000]) async {
    if (_finished) {
      return;
    }
    _finish();
    try {
      await _channel.sink.close(code);
    } catch (_) {
      // Closing a link that is already gone is not an error.
    }
  }
}
