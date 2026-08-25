// Injected time. Nothing under lib/src ever calls DateTime.now() directly;
// every method that needs "now" takes a Clock so the whole registry is a
// pure function of its own state plus this and an injected Random.

/// A source of the current time. The registry depends on this, not on
/// `DateTime.now()`, so its lifecycle logic is deterministically testable.
abstract class Clock {
  DateTime get now;
}

/// The real clock, used by the running server.
class SystemClock implements Clock {
  const SystemClock();

  @override
  DateTime get now => DateTime.now();
}

/// A clock a test can move by hand. Lives in `lib/`, not `test/`, because the
/// registry's public constructor takes a `Clock` and this is the only
/// implementation other than `SystemClock` that can drive it deterministically.
class FakeClock implements Clock {
  FakeClock(this._now);

  DateTime _now;

  @override
  DateTime get now => _now;

  void advance(Duration d) {
    _now = _now.add(d);
  }
}
