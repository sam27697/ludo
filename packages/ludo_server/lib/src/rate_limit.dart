// docs/PROTOCOL.md section 7's rate limits. Every clock reference here comes
// from the injected `Clock`, never from `DateTime.now()`, so this stays
// testable the same way the registry is.
//
// There is no device identifier anywhere in `docs/PROTOCOL.md`, so the
// "3 per hour per device" half of the `create_room` limit is not
// implemented. That is reported in this order's write-up, not invented
// around with a fabricated device id.

import 'clock.dart';

const Duration _createRoomWindow = Duration(hours: 1);
const int _createRoomLimit = 5;

const Duration _joinOrResumeWindow = Duration(minutes: 1);
const int _joinOrResumeLimit = 20;

const Duration _messageWindow = Duration(seconds: 1);
const int _messageWarnLimit = 30;
const int _messageCloseLimit = 60;

/// The outcome of the per-connection "any message" limiter,
/// `docs/PROTOCOL.md` section 7: "30 per second, then `RATE_LIMITED`, then
/// close at 60."
enum MessageRateOutcome { allowed, limited, mustClose }

/// A single sliding window over an injected clock: keeps only the
/// timestamps within the window and reports how many are left after adding
/// one more.
class _SlidingWindow {
  final List<DateTime> _hits = <DateTime>[];

  int recordAndCount(DateTime now, Duration window) {
    _hits.add(now);
    _hits.removeWhere((DateTime t) => now.difference(t) >= window);
    return _hits.length;
  }
}

/// Every rate limiter `docs/PROTOCOL.md` section 7 describes, keyed the way
/// each one is scoped: `create_room` and `join_room`/`resume` per IP, the
/// blanket per-message limit per connection.
class RateLimiter {
  RateLimiter({required Clock clock}) : _clock = clock;

  final Clock _clock;

  final Map<String, _SlidingWindow> _createRoomByIp = <String, _SlidingWindow>{};
  final Map<String, _SlidingWindow> _joinOrResumeByIp = <String, _SlidingWindow>{};
  final Map<Object, _SlidingWindow> _messagesByConnection = <Object, _SlidingWindow>{};

  /// True if this `create_room` may proceed. Counts the attempt either way,
  /// per connection scoped by IP.
  bool recordCreateRoom(String ip) {
    final _SlidingWindow window =
        _createRoomByIp.putIfAbsent(ip, () => _SlidingWindow());
    final int count = window.recordAndCount(_clock.now, _createRoomWindow);
    return count <= _createRoomLimit;
  }

  /// True if this `join_room` or `resume` may proceed. Counts the attempt
  /// either way, including a wrong code or a wrong seat token: that is what
  /// makes the room code space unenumerable rather than merely large.
  bool recordJoinOrResume(String ip) {
    final _SlidingWindow window =
        _joinOrResumeByIp.putIfAbsent(ip, () => _SlidingWindow());
    final int count = window.recordAndCount(_clock.now, _joinOrResumeWindow);
    return count <= _joinOrResumeLimit;
  }

  /// Any message at all, scoped to one connection. [connectionKey] is
  /// whatever the caller uses to identify one socket; it is never
  /// interpreted, only used as a map key.
  MessageRateOutcome recordMessage(Object connectionKey) {
    final _SlidingWindow window =
        _messagesByConnection.putIfAbsent(connectionKey, () => _SlidingWindow());
    final int count = window.recordAndCount(_clock.now, _messageWindow);
    if (count >= _messageCloseLimit) {
      return MessageRateOutcome.mustClose;
    }
    if (count > _messageWarnLimit) {
      return MessageRateOutcome.limited;
    }
    return MessageRateOutcome.allowed;
  }

  /// Drops a connection's per-message window once it disconnects, so a
  /// long-lived server does not accumulate a window per socket that will
  /// never be looked at again.
  void forget(Object connectionKey) {
    _messagesByConnection.remove(connectionKey);
  }
}
