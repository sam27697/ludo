// Pins `docs/PROTOCOL.md` section 7's rate limits at the `RateLimiter`
// level, against a `FakeClock` the test drives by hand. Written from the
// spec text quoted in work order 197, not from a reading of
// `lib/src/rate_limit.dart` -- two of the cases below (R3, R4's neighbours)
// are expected to fail on today's source for the same reason: `docs/
// PROTOCOL.md` section 7 says "only an attempt the limiter admits counts
// toward the 5", and `RateLimiter.recordCreateRoom` today records every
// attempt, admitted or not. Order 198 fixes that in the source; this file
// exists to prove the gap, not to paper over it.

import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

DateTime _t0() => DateTime.utc(2026, 1, 1);

void main() {
  group('create_room: 5 per hour per IP', () {
    test('R1: five recordCreateRoom(a) are true, the sixth is false', () {
      final FakeClock clock = FakeClock(_t0());
      final RateLimiter limiter = RateLimiter(clock: clock);

      for (int i = 1; i <= 5; i++) {
        expect(
          limiter.recordCreateRoom('a'),
          isTrue,
          reason: 'attempt $i for ip "a" must be admitted, five per hour '
              'per IP being the limit',
        );
      }
      expect(
        limiter.recordCreateRoom('a'),
        isFalse,
        reason: 'the sixth create_room attempt for ip "a" inside the same '
            'hour must be refused',
      );
    });

    test('R2: a different IP has its own bucket', () {
      final FakeClock clock = FakeClock(_t0());
      final RateLimiter limiter = RateLimiter(clock: clock);

      for (int i = 1; i <= 5; i++) {
        expect(
          limiter.recordCreateRoom('a'),
          isTrue,
          reason: 'setting up: attempt $i for ip "a" must be admitted',
        );
      }
      expect(
        limiter.recordCreateRoom('a'),
        isFalse,
        reason: 'setting up: ip "a" must be exhausted before checking "b"',
      );

      expect(
        limiter.recordCreateRoom('b'),
        isTrue,
        reason: 'ip "b" has sent no create_room yet; docs/PROTOCOL.md '
            'section 7 scopes this limit per IP, so "a" being exhausted '
            'must not affect "b"',
      );
    });

    test(
        'R3 (order 198): a refused attempt must not count toward the 5 '
        '-- RED on today\'s source, which records every attempt', () {
      final FakeClock clock = FakeClock(_t0());
      final RateLimiter limiter = RateLimiter(clock: clock);

      for (int i = 1; i <= 5; i++) {
        expect(
          limiter.recordCreateRoom('a'),
          isTrue,
          reason: 'setting up: attempt $i must be admitted at t0',
        );
      }

      // Ten refused attempts, spread over the next 59 minutes. Each one
      // must be refused (the bucket is already at its limit); the point
      // of this test is whether any of them leaves a mark that still
      // matters an hour after the FIRST admitted attempt.
      for (int i = 1; i <= 10; i++) {
        clock.advance(const Duration(minutes: 5));
        expect(
          limiter.recordCreateRoom('a'),
          isFalse,
          reason: 'refused attempt $i, at minute ${5 * i} after the first '
              'admitted attempt, must still be refused: the bucket was '
              'full and none of these attempts is supposed to widen it',
        );
      }

      // Elapsed so far: 50 minutes since t0. Advance the remaining 10
      // minutes so that exactly one hour has passed since the FIRST
      // admitted attempt.
      clock.advance(const Duration(minutes: 10));

      expect(
        limiter.recordCreateRoom('a'),
        isTrue,
        reason: 'docs/PROTOCOL.md section 7: "only an attempt the limiter '
            'admits counts toward the 5; a create_room answered '
            'RATE_LIMITED does not." Exactly one hour has passed since the '
            'first of the five admitted attempts, so that attempt must '
            'have aged out of the window and this attempt must be '
            'admitted -- regardless of the ten refused attempts in '
            'between, none of which should have counted. On today\'s '
            'source this is expected to read false instead: every one of '
            'the ten refused attempts above was also recorded, so the '
            'window is not actually empty yet. See work order 197/198.',
      );
    });

    test('R4: the create_room window slides', () {
      final FakeClock clock = FakeClock(_t0());
      final RateLimiter limiter = RateLimiter(clock: clock);

      // Five admitted attempts, ten minutes apart: t0, t0+10, ..., t0+40.
      for (int i = 0; i < 5; i++) {
        if (i > 0) {
          clock.advance(const Duration(minutes: 10));
        }
        expect(
          limiter.recordCreateRoom('a'),
          isTrue,
          reason: 'setting up: admitted attempt ${i + 1} at minute '
              '${10 * i} after t0',
        );
      }

      // 59 minutes after t0 (19 minutes after the fifth admitted
      // attempt): none of the five original attempts has aged out yet
      // (the oldest is 59 minutes old, the window is 60), so this must
      // still be refused.
      clock.advance(const Duration(minutes: 19));
      expect(
        limiter.recordCreateRoom('a'),
        isFalse,
        reason: 'at t0+59m the first admitted attempt (at t0) is only 59 '
            'minutes old, one minute short of aging out of the one-hour '
            'window, so the bucket must still read full',
      );

      // 60 minutes after t0: the first admitted attempt (at t0) is now
      // exactly one hour old and ages out, freeing one slot.
      clock.advance(const Duration(minutes: 1));
      expect(
        limiter.recordCreateRoom('a'),
        isTrue,
        reason: 'at t0+60m the attempt from t0 is exactly one hour old and '
            'must have aged out of the sliding window, freeing the slot '
            'this attempt takes',
      );

      // Immediately after: the slot just freed is taken again, so the
      // bucket reads full once more.
      expect(
        limiter.recordCreateRoom('a'),
        isFalse,
        reason: 'the call right after the one at t0+60m must be refused '
            'again -- the slot the previous attempt freed was immediately '
            'spent by that same attempt',
      );
    });
  });

  group('join_room / resume: 20 per minute per IP', () {
    test(
        'R5: twenty recordJoinOrResume(a) true, the 21st false, "b" '
        'unaffected, then true again after a minute', () {
      final FakeClock clock = FakeClock(_t0());
      final RateLimiter limiter = RateLimiter(clock: clock);

      for (int i = 1; i <= 20; i++) {
        expect(
          limiter.recordJoinOrResume('a'),
          isTrue,
          reason: 'attempt $i for ip "a" must be admitted, twenty per '
              'minute per IP being the limit; a wrong code counts the '
              'same as a right one',
        );
      }
      expect(
        limiter.recordJoinOrResume('a'),
        isFalse,
        reason: 'the 21st join_room/resume attempt for ip "a" inside the '
            'same minute must be refused',
      );

      expect(
        limiter.recordJoinOrResume('b'),
        isTrue,
        reason: 'ip "b" has sent nothing yet; this limit is scoped per '
            'IP, so "a" being exhausted must not affect "b"',
      );

      clock.advance(const Duration(minutes: 1));
      expect(
        limiter.recordJoinOrResume('a'),
        isTrue,
        reason: 'a full minute has passed since every one of ip "a"\'s '
            'twenty-one attempts, so every one of them must have aged out '
            'of the one-minute window',
      );
    });
  });

  group('any message: 30 per second, then RATE_LIMITED, then close at 60', () {
    test('R6: recordMessage boundaries at 30, 31, 59 and 60', () {
      final FakeClock clock = FakeClock(_t0());
      final RateLimiter limiter = RateLimiter(clock: clock);
      final Object key = Object();

      for (int i = 1; i <= 30; i++) {
        expect(
          limiter.recordMessage(key),
          MessageRateOutcome.allowed,
          reason: 'message $i on one connection, within the first second, '
              'must be allowed: the limit is 30 before any warning',
        );
      }

      expect(
        limiter.recordMessage(key),
        MessageRateOutcome.limited,
        reason: 'message 31 must be the first one answered RATE_LIMITED '
            '(without closing), one past the 30-per-second ceiling',
      );

      for (int i = 32; i <= 59; i++) {
        expect(
          limiter.recordMessage(key),
          MessageRateOutcome.limited,
          reason: 'message $i must still be RATE_LIMITED, not yet at the '
              '60-message close ceiling',
        );
      }

      expect(
        limiter.recordMessage(key),
        MessageRateOutcome.mustClose,
        reason: 'message 60 must be the first one that requires closing '
            'the connection, per "then close at 60"',
      );

      expect(
        limiter.recordMessage(key),
        MessageRateOutcome.mustClose,
        reason: 'message 61, had the socket not already been closed by '
            'the caller on message 60, must still read mustClose',
      );
    });

    test('a fresh connection key is its own bucket', () {
      final FakeClock clock = FakeClock(_t0());
      final RateLimiter limiter = RateLimiter(clock: clock);
      final Object busyKey = Object();
      final Object freshKey = Object();

      for (int i = 1; i <= 60; i++) {
        limiter.recordMessage(busyKey);
      }

      expect(
        limiter.recordMessage(freshKey),
        MessageRateOutcome.allowed,
        reason: 'a different connection key must not be affected by '
            'another connection having been rate limited or closed',
      );
    });
  });

  group('prune()', () {
    test(
        'R7: prune after the windows pass drops the entries, observable '
        'as a fresh full allowance afterwards', () {
      final FakeClock clock = FakeClock(_t0());
      final RateLimiter limiter = RateLimiter(clock: clock);

      for (int i = 1; i <= 5; i++) {
        expect(
          limiter.recordCreateRoom('a'),
          isTrue,
          reason: 'setting up: exhausting ip "a"\'s create_room bucket, '
              'attempt $i',
        );
      }
      expect(
        limiter.recordCreateRoom('a'),
        isFalse,
        reason: 'setting up: ip "a" must be at its limit before pruning',
      );

      for (int i = 1; i <= 20; i++) {
        expect(
          limiter.recordJoinOrResume('a'),
          isTrue,
          reason: 'setting up: exhausting ip "a"\'s join_room/resume '
              'bucket, attempt $i',
        );
      }
      expect(
        limiter.recordJoinOrResume('a'),
        isFalse,
        reason: 'setting up: ip "a" must be at its join/resume limit '
            'before pruning',
      );

      clock.advance(const Duration(hours: 1));
      limiter.prune();

      for (int i = 1; i <= 5; i++) {
        expect(
          limiter.recordCreateRoom('a'),
          isTrue,
          reason: 'after prune() and an hour passing, ip "a" must have a '
              'fresh, full create_room allowance -- attempt $i',
        );
      }
      expect(
        limiter.recordCreateRoom('a'),
        isFalse,
        reason: 'the fresh allowance is still five per hour, not '
            'unlimited: the sixth attempt in the new window must be '
            'refused',
      );

      for (int i = 1; i <= 20; i++) {
        expect(
          limiter.recordJoinOrResume('a'),
          isTrue,
          reason: 'after prune() and an hour passing, ip "a" must have a '
              'fresh, full join_room/resume allowance -- attempt $i',
        );
      }
      expect(
        limiter.recordJoinOrResume('a'),
        isFalse,
        reason: 'the fresh allowance is still twenty per minute, not '
            'unlimited: the 21st attempt in the new window must be '
            'refused',
      );
    });
  });
}
