// A test double for lib/src/net/transport.dart's WireTransport, written
// against that file's contract and nothing else: no implementation of
// RoomConnection has been read to build this.
//
// The contract this fake has to honour, because the protocol engine is
// allowed to rely on every word of it:
//   - `incoming` is single-subscription; the engine listens exactly once.
//   - `send` never throws, and a send after the link is gone is a silent
//     drop, not an error.
//   - `done` completes when the link is gone, for any reason, and never
//     completes with an error.
//   - `close` is idempotent: a second call, or a call after the far end
//     already vanished, is not an error.

import 'dart:async';

import 'package:ludo_client/src/net/transport.dart';

/// Driven from a test: push inbound text with [pushText], simulate the far
/// end vanishing with [endFromFarSide], and inspect [sentRaw] and
/// [closeCalls] to see what the engine under test did with this transport.
class FakeTransport implements WireTransport {
  final StreamController<String> _incoming = StreamController<String>();
  final Completer<void> _done = Completer<void>();
  bool _closed = false;

  /// Every string handed to [send], in call order, including strings sent
  /// while the transport was already closed would be wrong to record here:
  /// per the contract, those are silently dropped and never reach this list.
  final List<String> sentRaw = <String>[];

  /// The close code from every call to [close], in call order, including
  /// calls made after the transport was already closed (idempotent, but
  /// still observed here so a test can assert how many times the engine
  /// called it and with what code each time).
  final List<int> closeCalls = <int>[];

  /// True once this transport is closed, whether by [close] or by
  /// [endFromFarSide].
  bool get isClosed => _closed;

  @override
  Stream<String> get incoming => _incoming.stream;

  @override
  void send(String text) {
    if (_closed) {
      // Silent drop. WireTransport.send's contract: never throws, and
      // specifically not when the link is already gone.
      return;
    }
    sentRaw.add(text);
  }

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close([int code = 1000]) async {
    closeCalls.add(code);
    if (_closed) {
      return;
    }
    _closed = true;
    if (!_incoming.isClosed) {
      await _incoming.close();
    }
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  /// Test control: deliver [text] to the engine as if the far end sent it.
  ///
  /// Throws a plain [StateError] (a test-harness misuse signal, not part of
  /// the WireTransport contract) if the transport is already closed; a real
  /// socket cannot receive after it is gone and a test that tries to is
  /// testing nothing real.
  void pushText(String text) {
    if (_closed) {
      throw StateError('FakeTransport.pushText after close');
    }
    _incoming.add(text);
  }

  /// Test control: end the incoming stream and complete [done] as if the far
  /// end closed the link, without this side ever calling [close].
  void endFromFarSide() {
    if (_closed) {
      return;
    }
    _closed = true;
    unawaited(_incoming.close());
    if (!_done.isCompleted) {
      _done.complete();
    }
  }
}
