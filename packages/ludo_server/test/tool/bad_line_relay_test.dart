// The impairment relay of the bad-line probe (tool/probe/line.dart): delay,
// order, cap and seeded loss on a fake clock, plus one run through real
// loopback sockets with generous bounds.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';

import '../../tool/probe/line.dart';

/// A pipe on a fake clock with every delivery recorded as (time, bytes).
class _Rig {
  _Rig(LineProfile profile, int seed) {
    pipe = LinePipe(
      profile: profile,
      random: Random(seed),
      clock: clock,
      deliver: (List<int> b) => delivered.add((clock.now, b)),
      keepRecords: true,
    );
  }

  final FakeLineClock clock = FakeLineClock();
  final List<(Duration, List<int>)> delivered = <(Duration, List<int>)>[];
  late final LinePipe pipe;

  List<int> get allBytes =>
      <int>[for (final (Duration _, List<int> b) in delivered) ...b];
}

/// A clock whose timers fire a little before the time they were set for, as a
/// real timer can against a stopwatch.
class _EarlyClock implements LineClock {
  _EarlyClock(this.earlyBy);
  final Duration earlyBy;
  Duration _now = Duration.zero;
  final List<(Duration, void Function())> _timers =
      <(Duration, void Function())>[];

  @override
  Duration get now => _now;

  @override
  void at(Duration when, void Function() callback) {
    _timers.add((when, callback));
    if (_running) {
      _onTime.add(callback);
    }
  }

  bool _running = false;
  final Set<void Function()> _onTime = <void Function()>{};

  /// Fires each timer set before the run [earlyBy] before its time, and each
  /// timer the pipe sets in answer exactly on time.
  void runAll() {
    _running = true;
    int guard = 0;
    while (_timers.isNotEmpty) {
      expect(++guard, lessThan(10000), reason: 'timers never settle');
      _timers.sort(
          ((Duration, void Function()) a, (Duration, void Function()) b) =>
              a.$1.compareTo(b.$1));
      final (Duration, void Function()) next = _timers.removeAt(0);
      final Duration when = next.$1;
      final bool early = !_onTime.contains(next.$2);
      final Duration fireAt = early ? when - earlyBy : when;
      _now = fireAt > _now ? fireAt : _now;
      next.$2();
    }
  }
}

const LineProfile _fixed = LineProfile(name: 'fixed', oneWayDelayMs: 300);
const LineProfile _jitter =
    LineProfile(name: 'jitter', oneWayDelayMs: 300, jitterMs: 100);

void main() {
  group('delay', () {
    test('a fixed one-way delay lands every segment exactly that late', () {
      final _Rig r = _Rig(_fixed, 1);
      r.pipe.send(List<int>.filled(100, 7));
      r.clock.advanceTo(const Duration(milliseconds: 299));
      expect(r.delivered, isEmpty,
          reason: 'delivered before the 300 ms delay had passed');
      r.clock.advanceTo(const Duration(milliseconds: 300));
      expect(r.delivered, hasLength(1));
      expect(r.delivered.single.$1, const Duration(milliseconds: 300));
    });

    test('jitter keeps every segment within delay +- jitter of its send', () {
      for (final int seed in <int>[1, 2, 3, 1124]) {
        final _Rig r = _Rig(_jitter, seed);
        for (int i = 0; i < 200; i++) {
          r.clock.advanceTo(Duration(milliseconds: i * 500));
          r.pipe.send(<int>[i % 256]);
        }
        r.clock.runAll();
        for (final SegmentRecord s in r.pipe.records) {
          final int ms = (s.deliverAt - s.sentAt).inMicroseconds ~/ 1000;
          expect(ms, inInclusiveRange(200, 400),
              reason: 'seed=$seed: segment sent at ${s.sentAt} delivered '
                  '${ms} ms later, expected 300 +- 100');
        }
        final Set<int> distinct = r.pipe.records
            .map((SegmentRecord s) => (s.deliverAt - s.sentAt).inMilliseconds)
            .toSet();
        expect(distinct.length, greaterThan(20),
            reason: 'seed=$seed: jitter produced ${distinct.length} distinct '
                'delays in 200 segments');
      }
    });

    test('no profile at all delivers synchronously', () {
      final _Rig r = _Rig(const LineProfile(name: 'none'), 1);
      r.pipe.send(<int>[1, 2, 3]);
      expect(r.delivered, hasLength(1));
      expect(r.delivered.single.$1, Duration.zero);
    });

    test('a timer that fires early does not strand a segment', () {
      final _EarlyClock clock = _EarlyClock(const Duration(microseconds: 600));
      final List<int> got = <int>[];
      final LinePipe pipe = LinePipe(
        profile: _fixed,
        random: Random(1),
        clock: clock,
        deliver: got.addAll,
      );
      pipe.send(<int>[1, 2, 3]);
      pipe.send(<int>[4]);
      clock.runAll();
      expect(got, <int>[1, 2, 3, 4],
          reason: 'a timer 600 us early left bytes undelivered with nothing '
              'left to wake the pipe (the 11 s stall seen on seed 1124)');
    });
  });

  group('order', () {
    test('bytes arrive in the order sent under jitter and loss', () {
      for (final int seed in <int>[1, 7, 99, 1124]) {
        final LineProfile p = LineProfile(
          name: 'rough',
          oneWayDelayMs: 300,
          jitterMs: 100,
          lossRate: 0.3,
          rateBitsPerSecond: 256000,
        );
        final _Rig r = _Rig(p, seed);
        final List<int> sent = <int>[];
        final Random gen = Random(seed);
        for (int i = 0; i < 60; i++) {
          r.clock.advanceTo(Duration(milliseconds: i * 20));
          final List<int> chunk = List<int>.generate(
              1 + gen.nextInt(4000), (_) => gen.nextInt(256));
          sent.addAll(chunk);
          r.pipe.send(chunk);
        }
        r.clock.runAll();
        expect(r.allBytes, sent,
            reason: 'seed=$seed: bytes reordered, lost or duplicated');
        Duration last = Duration.zero;
        for (final (Duration t, List<int> _) in r.delivered) {
          expect(t >= last, isTrue,
              reason: 'seed=$seed: delivery times went backwards');
          last = t;
        }
      }
    });

    test('a lost segment holds up the ones behind it', () {
      // Loss on every first try: each segment waits one RTO, order kept.
      final _Rig r = _Rig(
          const LineProfile(
              name: 'lossy', lossRate: 0.999, rtoMs: 100, segmentBytes: 10),
          5);
      r.pipe.send(List<int>.generate(50, (int i) => i));
      r.clock.runAll();
      expect(r.allBytes, List<int>.generate(50, (int i) => i));
      final List<SegmentRecord> rec = r.pipe.records;
      for (int i = 1; i < rec.length; i++) {
        expect(rec[i].deliverAt >= rec[i - 1].deliverAt, isTrue,
            reason: 'segment $i overtook segment ${i - 1}');
      }
    });
  });

  group('cap', () {
    test('256 kbit/s: the last byte cannot arrive before the wire time', () {
      const LineProfile p = LineProfile(
          name: 'cap', rateBitsPerSecond: 256000, segmentBytes: 1400);
      final _Rig r = _Rig(p, 1);
      r.pipe.send(List<int>.filled(14000, 1));
      r.clock.runAll();
      // 10 segments of 1400 payload + 40 header bytes at 256000 bit/s.
      final double wireSeconds = 10 * (1400 + 40) * 8 / 256000;
      final Duration last = r.delivered.last.$1;
      expect(last.inMicroseconds / 1e6, closeTo(wireSeconds, 0.001),
          reason: '14000 bytes through 256 kbit/s should take '
              '${wireSeconds.toStringAsFixed(3)} s, took '
              '${(last.inMicroseconds / 1e6).toStringAsFixed(3)} s');
      expect(r.allBytes.length, 14000);
    });

    test('over any window the delivered rate stays at or under the cap', () {
      const LineProfile p = LineProfile(
          name: 'cap', rateBitsPerSecond: 256000, segmentBytes: 1400);
      final _Rig r = _Rig(p, 1);
      for (int i = 0; i < 20; i++) {
        r.pipe.send(List<int>.filled(1400, 1));
      }
      r.clock.runAll();
      final List<Duration> times = <Duration>[
        for (final (Duration t, List<int> _) in r.delivered) t
      ];
      // Any k consecutive segments need at least (k-1) segment times on the
      // wire between the first and the last arrival.
      final double segSeconds = (1400 + 40) * 8 / 256000;
      for (int i = 0; i + 5 < times.length; i++) {
        final double span = (times[i + 5] - times[i]).inMicroseconds / 1e6;
        expect(span, greaterThanOrEqualTo(5 * segSeconds - 0.001),
            reason: 'segments $i..${i + 5} arrived in ${span}s, the cap '
                'allows no less than ${5 * segSeconds}s');
      }
    });

    test('an idle line does not bank credit', () {
      const LineProfile p = LineProfile(name: 'cap', rateBitsPerSecond: 256000);
      final _Rig r = _Rig(p, 1);
      r.pipe.send(List<int>.filled(1400, 1));
      r.clock.advanceTo(const Duration(seconds: 30));
      r.pipe.send(List<int>.filled(1400, 1));
      r.clock.runAll();
      final Duration second = r.delivered.last.$1 - const Duration(seconds: 30);
      expect(second.inMilliseconds, greaterThanOrEqualTo(44),
          reason: 'a segment after 30 s idle still needs its own '
              '${(1440 * 8 / 256).round()} ms on the wire, took '
              '${second.inMilliseconds} ms');
    });
  });

  group('seeded loss', () {
    List<(int, int)> schedule(int seed) {
      const LineProfile p = LineProfile(
          name: 'loss', oneWayDelayMs: 300, jitterMs: 100, lossRate: 0.03);
      final _Rig r = _Rig(p, seed);
      for (int i = 0; i < 2000; i++) {
        r.clock.advanceTo(Duration(milliseconds: i * 10));
        r.pipe.send(<int>[i % 256]);
      }
      r.clock.runAll();
      return <(int, int)>[
        for (final SegmentRecord s in r.pipe.records)
          (s.deliverAt.inMicroseconds, s.losses)
      ];
    }

    test('one seed gives one schedule, another seed a different one', () {
      expect(schedule(1124), schedule(1124),
          reason: 'seed=1124 produced two different schedules');
      expect(schedule(1124), isNot(schedule(1125)),
          reason: 'seeds 1124 and 1125 produced the same schedule');
    });

    test('the loss rate over many segments is near the profile', () {
      int lost = 0;
      int total = 0;
      for (final int seed in <int>[1, 2, 3, 4, 5]) {
        final List<(int, int)> s = schedule(seed);
        total += s.length;
        lost += s.where(((int, int) e) => e.$2 > 0).length;
      }
      final double rate = lost / total;
      expect(rate, inInclusiveRange(0.02, 0.04),
          reason: '$lost of $total segments lost = $rate, profile says 0.03');
    });

    test('a loss is a retransmission delay, never missing bytes', () {
      const LineProfile p =
          LineProfile(name: 'loss', lossRate: 0.5, rtoMs: 1000);
      final _Rig r = _Rig(p, 3);
      final List<int> sent = List<int>.generate(1400 * 40, (int i) => i % 251);
      r.pipe.send(sent);
      r.clock.runAll();
      expect(r.allBytes, sent);
      expect(r.pipe.segmentsLost, greaterThan(0));
      for (final SegmentRecord s
          in r.pipe.records.where((SegmentRecord s) => s.losses == 1)) {
        expect(s.deliverAt - s.sentAt >= const Duration(milliseconds: 1000),
            isTrue,
            reason: 'one loss must cost at least one RTO (1000 ms)');
      }
      for (final SegmentRecord s
          in r.pipe.records.where((SegmentRecord s) => s.losses == 2)) {
        expect(s.deliverAt - s.sentAt >= const Duration(milliseconds: 3000),
            isTrue,
            reason: 'a repeat loss waits twice the first RTO: 1000 + 2000 ms');
      }
    });
  });

  group('through real sockets', () {
    test('echo through the relay: order kept, delay present, close drains',
        () async {
      final ServerSocket upstream =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(upstream.close);
      final List<int> payload =
          List<int>.generate(6000, (int i) => (i * 7) % 256);
      upstream.listen((Socket s) async {
        // Answers with the payload and hangs up at once: the bytes still in
        // flight on the line must reach the client before it sees the close.
        s.add(payload);
        await s.flush();
        await s.close();
      });
      const LineProfile p = LineProfile(
          name: 'real', oneWayDelayMs: 80, jitterMs: 20, rateBitsPerSecond: 0);
      final LineRelay relay = await LineRelay.start(
        upstreamHost: '127.0.0.1',
        upstreamPort: upstream.port,
        profile: p,
        seed: 42,
      );
      addTearDown(relay.close);
      final Stopwatch sw = Stopwatch()..start();
      final Socket c = await Socket.connect('127.0.0.1', relay.port);
      final List<int> got = <int>[];
      final Completer<void> done = Completer<void>();
      Duration? firstByte;
      c.listen((List<int> b) {
        firstByte ??= sw.elapsed;
        got.addAll(b);
      }, onDone: done.complete);
      await done.future.timeout(const Duration(seconds: 20),
          onTimeout: () => fail('relay never closed the client after the '
              'upstream hung up; got ${got.length} of ${payload.length} bytes'));
      expect(got, payload,
          reason: 'got ${got.length} of ${payload.length} bytes before the '
              'close; the relay cut in-flight bytes off or reordered them');
      expect(firstByte!.inMilliseconds, greaterThanOrEqualTo(60),
          reason: 'first byte after ${firstByte!.inMilliseconds} ms, expected '
              'at least the 80 ms delay minus 20 ms jitter (generous bound)');
      c.destroy();
    });
  });
}
