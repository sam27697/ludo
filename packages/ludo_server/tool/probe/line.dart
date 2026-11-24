// A bad line, built in user space: there is no root on the hosts this runs
// on, so `tc netem` is not available. A [LinePipe] carries one direction of
// one TCP connection and impairs it the way netem plus TCP would look to the
// application: a fixed one-way delay, uniform jitter, a bandwidth cap, and
// loss as TCP sees it. A lost segment is never dropped bytes; it is the
// retransmission timeout (doubling on a repeat loss of the same segment)
// added to that segment's delivery. Bytes are always delivered in order: a
// segment never overtakes an earlier one, so a late or lost segment holds up
// every segment behind it, which is TCP's head-of-line blocking.
//
// Every random draw comes from the [Random] a pipe is given, seeded by the
// caller, in a fixed order per segment: one jitter draw (only when jitter is
// non-zero), then loss draws until one says "delivered" (only when loss is
// non-zero). The same seed and the same byte stream give the same schedule.
//
// [LineRelay] puts two pipes, one each way, between an accepted client
// socket and an upstream TCP connection.

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';

/// The impairment of one direction of a line. Every client gets one
/// [LineRelay] and both of its directions use the same profile.
class LineProfile {
  const LineProfile({
    required this.name,
    this.oneWayDelayMs = 0,
    this.jitterMs = 0,
    this.lossRate = 0,
    this.segmentBytes = 1400,
    this.rateBitsPerSecond = 0,
    this.rtoMs = 1000,
    this.headerBytes = 40,
  })  : assert(lossRate >= 0 && lossRate < 1),
        assert(segmentBytes > 0);

  final String name;

  /// Fixed delay added to every segment, each way.
  final int oneWayDelayMs;

  /// Each segment gets a further delay drawn uniformly from
  /// `[-jitterMs, +jitterMs]`, each way.
  final int jitterMs;

  /// Chance that one transmission of one segment is lost.
  final double lossRate;

  /// The largest segment, in payload bytes.
  final int segmentBytes;

  /// Bandwidth cap each way, in bits per second of payload plus
  /// [headerBytes] per segment. 0 is no cap.
  final int rateBitsPerSecond;

  /// The retransmission delay of the first loss of a segment; a repeat loss
  /// of the same segment waits twice the previous one.
  final int rtoMs;

  /// TCP/IP header bytes counted against the cap for every segment.
  final int headerBytes;

  static const List<String> names = <String>['none', 'syria-bad'];

  /// The named profiles. `syria-bad` is the order's: 300 ms each way (600 ms
  /// RTT), jitter 100 ms each way, 3% loss per segment of up to 1400 bytes,
  /// 256 kbit/s each way.
  static LineProfile named(String name, {int rtoMs = 1000}) {
    switch (name) {
      case 'none':
        return LineProfile(name: 'none', rtoMs: rtoMs);
      case 'syria-bad':
        return LineProfile(
          name: 'syria-bad',
          oneWayDelayMs: 300,
          jitterMs: 100,
          lossRate: 0.03,
          segmentBytes: 1400,
          rateBitsPerSecond: 256000,
          rtoMs: rtoMs,
        );
    }
    throw ArgumentError.value(
        name, 'profile', 'expected one of ${names.join(', ')}');
  }

  bool get isTransparent =>
      oneWayDelayMs == 0 &&
      jitterMs == 0 &&
      lossRate == 0 &&
      rateBitsPerSecond == 0;

  /// One line naming every parameter.
  String describe() => 'profile=$name one_way_delay=${oneWayDelayMs}ms '
      'jitter=+-${jitterMs}ms(uniform) loss=${(lossRate * 100).toStringAsFixed(1)}%'
      '/segment segment<=${segmentBytes}B '
      'rate=${rateBitsPerSecond == 0 ? 'uncapped' : '${rateBitsPerSecond ~/ 1000}kbit/s'} '
      'header=${headerBytes}B/segment rto=${rtoMs}ms(doubling) '
      'each way, order kept';

  /// What a reader with root would type for the same line on both ends of
  /// a link (egress of each host; ingress needs an ifb device).
  String netemLine() {
    if (isTransparent) {
      return 'tc qdisc del dev eth0 root  # no impairment';
    }
    final List<String> parts = <String>['tc qdisc add dev eth0 root netem'];
    if (oneWayDelayMs > 0 || jitterMs > 0) {
      parts.add('delay ${oneWayDelayMs}ms');
      if (jitterMs > 0) {
        parts.add('${jitterMs}ms distribution uniform');
      }
    }
    if (lossRate > 0) {
      parts.add('loss ${(lossRate * 100).toStringAsFixed(1)}%');
    }
    if (rateBitsPerSecond > 0) {
      parts.add('rate ${rateBitsPerSecond ~/ 1000}kbit');
    }
    return parts.join(' ');
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'one_way_delay_ms': oneWayDelayMs,
        'jitter_ms_uniform_plus_minus': jitterMs,
        'loss_per_segment': lossRate,
        'segment_bytes_max': segmentBytes,
        'rate_bits_per_second_each_way': rateBitsPerSecond,
        'header_bytes_per_segment': headerBytes,
        'rto_ms_first': rtoMs,
        'rto_doubling': true,
        'order_kept': true,
      };
}

/// Time and timers for a pipe. [RealLineClock] in the tool, a fake in tests.
abstract class LineClock {
  Duration get now;
  void at(Duration when, void Function() callback);
}

class RealLineClock implements LineClock {
  RealLineClock() : _watch = Stopwatch()..start();

  final Stopwatch _watch;

  @override
  Duration get now => _watch.elapsed;

  @override
  void at(Duration when, void Function() callback) {
    final Duration wait = when - now;
    Timer(wait.isNegative ? Duration.zero : wait, callback);
  }
}

/// A clock that moves only when told to; timers fire in time order, and in
/// the order they were set when their times are equal.
class FakeLineClock implements LineClock {
  Duration _now = Duration.zero;
  int _order = 0;
  final SplayTreeMap<(int, int), void Function()> _timers =
      SplayTreeMap<(int, int), void Function()>(
    ((int, int) a, (int, int) b) =>
        a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2),
  );

  @override
  Duration get now => _now;

  @override
  void at(Duration when, void Function() callback) {
    _timers[(when.inMicroseconds, _order++)] = callback;
  }

  /// Moves to [to], firing every timer due on the way in time order.
  void advanceTo(Duration to) {
    while (_timers.isNotEmpty && _timers.firstKey()!.$1 <= to.inMicroseconds) {
      final (int, int) key = _timers.firstKey()!;
      final void Function() callback = _timers.remove(key)!;
      _now = Duration(microseconds: key.$1);
      callback();
    }
    _now = to;
  }

  /// Fires every pending timer.
  void runAll() {
    while (_timers.isNotEmpty) {
      advanceTo(Duration(microseconds: _timers.lastKey()!.$1));
    }
  }
}

/// One segment's schedule, kept for tests and for the report.
class SegmentRecord {
  SegmentRecord(this.sentAt, this.deliverAt, this.bytes, this.losses);
  final Duration sentAt;
  final Duration deliverAt;
  final int bytes;
  final int losses;
}

/// One direction of one impaired TCP connection.
class LinePipe {
  LinePipe({
    required this.profile,
    required Random random,
    required this.clock,
    required this.deliver,
    this.keepRecords = false,
  }) : _random = random;

  final LineProfile profile;
  final Random _random;
  final LineClock clock;
  final void Function(List<int> bytes) deliver;
  final bool keepRecords;

  final Queue<(Duration, List<int>)> _queue = Queue<(Duration, List<int>)>();
  Duration _linkFreeAt = Duration.zero;
  Duration _lastDeliverAt = Duration.zero;

  int bytes = 0;
  int segments = 0;
  int lossEvents = 0;
  int segmentsLost = 0;
  final List<SegmentRecord> records = <SegmentRecord>[];

  /// Takes [data] from the sending side at [clock.now], splits it into
  /// segments and schedules each one's delivery.
  void send(List<int> data) {
    for (int start = 0; start < data.length; start += profile.segmentBytes) {
      final int end = min(start + profile.segmentBytes, data.length);
      _sendSegment(data.sublist(start, end));
    }
  }

  void _sendSegment(List<int> segment) {
    final Duration now = clock.now;
    bytes += segment.length;
    segments++;
    Duration txEnd = now;
    if (profile.rateBitsPerSecond > 0) {
      final Duration txStart = _linkFreeAt > now ? _linkFreeAt : now;
      final int bits = (segment.length + profile.headerBytes) * 8;
      txEnd = txStart +
          Duration(
              microseconds:
                  (bits * 1000000 / profile.rateBitsPerSecond).round());
      _linkFreeAt = txEnd;
    }
    int delayUs = profile.oneWayDelayMs * 1000;
    if (profile.jitterMs > 0) {
      delayUs +=
          ((_random.nextDouble() * 2 - 1) * profile.jitterMs * 1000).round();
    }
    int losses = 0;
    if (profile.lossRate > 0) {
      int rto = profile.rtoMs;
      while (_random.nextDouble() < profile.lossRate) {
        delayUs += rto * 1000;
        rto *= 2;
        losses++;
      }
    }
    if (losses > 0) {
      segmentsLost++;
      lossEvents += losses;
    }
    Duration deliverAt = txEnd + Duration(microseconds: max(0, delayUs));
    if (deliverAt < _lastDeliverAt) {
      deliverAt = _lastDeliverAt;
    }
    _lastDeliverAt = deliverAt;
    if (keepRecords) {
      records.add(SegmentRecord(now, deliverAt, segment.length, losses));
    }
    if (deliverAt <= now && _queue.isEmpty) {
      deliver(segment);
      return;
    }
    _queue.add((deliverAt, segment));
    _arm();
  }

  /// True while a timer for the head of the queue is pending.
  bool _armed = false;
  final List<void Function()> _drainWaiters = <void Function()>[];

  /// Schedules one wake-up for the segment at the head of the queue. A real
  /// timer can fire a fraction of a millisecond before the stopwatch reads
  /// the due time, so [_flush] re-arms for whatever is still queued; without
  /// that a segment due a hair later than its timer would sit until the next
  /// send, which on a quiet line is never.
  void _arm() {
    if (_armed || _queue.isEmpty) {
      return;
    }
    _armed = true;
    clock.at(_queue.first.$1, () {
      _armed = false;
      _flush();
    });
  }

  void _flush() {
    final Duration now = clock.now;
    while (_queue.isNotEmpty && _queue.first.$1 <= now) {
      deliver(_queue.removeFirst().$2);
    }
    _arm();
    if (_queue.isEmpty && _drainWaiters.isNotEmpty) {
      final List<void Function()> waiters =
          List<void Function()>.of(_drainWaiters);
      _drainWaiters.clear();
      for (final void Function() w in waiters) {
        w();
      }
    }
  }

  /// True when no segment is waiting for its delivery time.
  bool get isDrained => _queue.isEmpty;

  /// Runs [callback] once nothing is queued; at once when that is already so.
  void whenDrained(void Function() callback) {
    if (_queue.isEmpty) {
      callback();
    } else {
      _drainWaiters.add(callback);
    }
  }

  Map<String, Object?> statsJson() => <String, Object?>{
        'bytes': bytes,
        'segments': segments,
        'segments_lost_at_least_once': segmentsLost,
        'loss_events': lossEvents,
      };
}

/// One client's line: listens on a loopback port, accepts exactly one
/// connection, opens one upstream connection and runs a [LinePipe] each way.
class LineRelay {
  LineRelay._(this._server, this.profile, this.seed, this.clock);

  final ServerSocket _server;
  final LineProfile profile;
  final int seed;
  final LineClock clock;

  Socket? _client;
  Socket? _upstream;
  LinePipe? up;
  LinePipe? down;
  final Completer<void> _closed = Completer<void>();

  int get port => _server.port;

  /// Starts listening. [seed] seeds both directions (`seed * 2` upstream,
  /// `seed * 2 + 1` downstream).
  static Future<LineRelay> start({
    required String upstreamHost,
    required int upstreamPort,
    required LineProfile profile,
    required int seed,
    LineClock? clock,
  }) async {
    final ServerSocket server =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final LineRelay relay =
        LineRelay._(server, profile, seed, clock ?? RealLineClock());
    server.listen((Socket client) async {
      if (relay._client != null) {
        client.destroy();
        return;
      }
      relay._client = client;
      client.setOption(SocketOption.tcpNoDelay, true);
      final Socket upstream = await Socket.connect(upstreamHost, upstreamPort);
      upstream.setOption(SocketOption.tcpNoDelay, true);
      relay._upstream = upstream;
      relay.up = LinePipe(
        profile: profile,
        random: Random(seed * 2),
        clock: relay.clock,
        deliver: (List<int> b) => _safeAdd(upstream, b),
      );
      relay.down = LinePipe(
        profile: profile,
        random: Random(seed * 2 + 1),
        clock: relay.clock,
        deliver: (List<int> b) => _safeAdd(client, b),
      );
      client.listen(
        relay.up!.send,
        onDone: relay._closeAfterDrain,
        onError: (Object _) => relay.close(),
      );
      upstream.listen(
        relay.down!.send,
        onDone: relay._closeAfterDrain,
        onError: (Object _) => relay.close(),
      );
    });
    return relay;
  }

  static void _safeAdd(Socket socket, List<int> bytes) {
    try {
      socket.add(bytes);
    } on Object {
      // The other side already went away; the relay is closing.
    }
  }

  /// One end hung up. Whatever the line still holds in flight, in either
  /// direction, is delivered first, as it would be on a real link; closing at
  /// once would cut the last frames of a game short.
  void _closeAfterDrain() {
    final LinePipe? u = up;
    final LinePipe? d = down;
    if (u == null || d == null) {
      close();
      return;
    }
    u.whenDrained(() => d.whenDrained(close));
  }

  Future<void> close() async {
    if (_closed.isCompleted) {
      return;
    }
    _closed.complete();
    _client?.destroy();
    _upstream?.destroy();
    await _server.close();
  }
}
