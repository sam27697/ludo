// The seam between the protocol and the socket that carries it.
//
// Everything above this line in the client is pure: `frame.dart` turns bytes
// into a typed [Frame], `snapshot.dart` turns a `room` payload into a typed
// model, and neither of them can open a connection or read a clock. This file
// is the one declaration that lets the layer above stay that way. It is an
// interface and nothing else: no implementation lives here, and adding one
// would put `dart:io` back into the part of the tree that has to run under
// `flutter test` with no network.
//
// Two implementations are expected. The real one wraps a web socket and lives
// in its own file so that the package's test suite never imports it. The fake
// one lives in the test tree, is driven frame by frame, and is how the
// protocol engine is proved without a server.

import 'dart:async';

/// A duplex text channel, which is the whole of what the protocol engine
/// needs from a socket.
///
/// Deliberately not a `WebSocket`: the engine has no business knowing about
/// handshakes, ping frames, sub-protocols or binary opcodes. It sends text and
/// it receives text.
abstract class WireTransport {
  /// Every text message the far end sent, in arrival order.
  ///
  /// Single subscription. The protocol engine listens exactly once and
  /// re-broadcasts to its own consumers; a transport that returns a broadcast
  /// stream here still satisfies the contract, but nothing may rely on being
  /// able to listen twice.
  ///
  /// The stream closes when the link is gone. It may also emit an error before
  /// closing, and the engine treats an error and a close as the same event: the
  /// connection is over either way and the recovery is `resume`, never a retry
  /// of the frame in flight.
  Stream<String> get incoming;

  /// Queues [text] for delivery.
  ///
  /// Never throws, and specifically not when the link is already gone. A send
  /// on a dead transport is dropped. This is deliberate: the caller cannot
  /// distinguish "the socket died a microsecond ago" from "the socket died a
  /// microsecond from now", so making one of those two an exception and the
  /// other a silent no-op would produce a race that only ever fails in the
  /// field. The engine learns that the link is gone from [done], which is a
  /// signal it can act on, rather than from a throw at an arbitrary call site.
  void send(String text);

  /// Completes when the link is gone, for any reason: the far end closed, the
  /// near end called [close], or the connection failed.
  ///
  /// Never completes with an error. A transport failure is an ordinary end of
  /// life for a socket on a phone, not an exceptional condition, and a future
  /// that can reject forces every holder to guard it.
  Future<void> get done;

  /// Closes the link, idempotently: calling it twice, or calling it after the
  /// far end already closed, is not an error and does not throw.
  ///
  /// [code] is an RFC 6455 close code. The default is 1000, a normal closure.
  /// docs/PROTOCOL.md section 7.1 pins the codes the *server* sends; a client
  /// closing deliberately has no reason to send anything but 1000.
  Future<void> close([int code = 1000]);
}

/// Opens a transport to [url].
///
/// The engine takes one of these rather than a [WireTransport] directly,
/// because reconnection means opening a *second* transport after the first is
/// done, and an engine handed a single live socket could never do that.
///
/// The returned future completes with an error if the connection cannot be
/// established. That error is the caller's to handle: it is the one failure a
/// client can usefully retry with a backoff, unlike a mid-session drop.
typedef TransportConnector = Future<WireTransport> Function(Uri url);
