// Order C-672t: the proof of docs/PROTOCOL.md section 30, the ruleset of
// 2026-12 (the shared release), over real sockets against a real WireServer
// with a fake clock, and against bin/server.dart as a real child process for
// the environment switch.
//
// Written from the section, from docs/RULES.md 3.2c and from
// docs/ENGINE_API.md section 13 only. The verify record and the page are in
// c672_shared_release_record_test.dart; the shared harness is
// support/c672_harness.dart.
//
// Board and dice. No production hook is used. A position that dice would take
// hours to reach (a drought of nine, an opponent block on an entry square, a
// seat one step from home) is built by rewriting the room's engine state
// through the registry between frames; faces that matter are steered with the
// offline search of support/dice_oracle.dart, so every run is deterministic
// and a failure names its scenario (the scenario name is the reproduction:
// dart test test/c672_shared_release_test.dart --plain-name "<scenario>").
// No test sleeps: every wait is on a frame, a socket close or a ping barrier.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:ludo_engine/ludo_engine.dart' as engine;
import 'package:test/test.dart';

import 'support/c672_harness.dart';
import 'support/wire_harness.dart';

// ---------------------------------------------------------------------------
// Local helpers.
// ---------------------------------------------------------------------------

/// Sets seat [seat]'s drought to 9 (the next non-6 with every token in the
/// yard is its tenth), rolls for it and returns what every seat saw.
Future<Map<int, List<Frame>>> rollToOffer(Table t, {int seat = 0}) {
  final List<int> drought = <int>[0, 0, 0, 0];
  drought[seat] = 9;
  force(t, drought: drought);
  return t.step(seat, 'roll', <String, Object?>{});
}

Frame only(Fixture fx, List<Frame> frames, String type, String what) {
  final List<Frame> hit = ofType(frames, type);
  fx.eq(
      hit.length, 1, '$what: exactly one "$type" frame in ${typesOf(frames)}');
  return hit.single;
}

List<Frame> without(List<Frame> frames, String type) => <Frame>[
      for (final Frame f in frames)
        if (f['t'] != type) f
    ];

Map<String, Object?> seatObject(Map<String, Object?> snap, int seat) {
  for (final Object? s in snap['seats']! as List<Object?>) {
    final Map<String, Object?> m = s! as Map<String, Object?>;
    if (m['seat'] == seat) {
      return m;
    }
  }
  throw TestFailure('no seat $seat in snapshot ${snap['seats']}');
}

Future<Directory> packageRoot() async {
  final Uri? libUri = await Isolate.resolvePackageUri(
    Uri.parse('package:ludo_server/ludo_server.dart'),
  );
  if (libUri == null) {
    throw TestFailure('could not resolve package:ludo_server to a file URI');
  }
  return File.fromUri(libUri).parent.parent;
}

Map<String, String> childEnvironment(Map<String, String> extra) {
  final Map<String, String> parent = Platform.environment;
  return <String, String>{
    for (final String key in <String>[
      'PATH',
      'HOME',
      'PUB_CACHE',
      'TMPDIR',
      'XDG_CONFIG_HOME',
      'XDG_CACHE_HOME',
    ])
      if (parent[key] != null) key: parent[key]!,
    ...extra,
  };
}

Future<int> freePort() async {
  final ServerSocket probe =
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final int port = probe.port;
  await probe.close();
  return port;
}

Future<bool> isListening(int port) async {
  try {
    final Socket s = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: const Duration(seconds: 1),
    );
    s.destroy();
    return true;
  } on SocketException {
    return false;
  } on TimeoutException {
    return false;
  }
}

/// Asserts the four frames of a taken release, in order, for [seat] viewing
/// the step and returns them as moved, granted, passed, turn.
List<Frame> expectTakeFrames(
  Fixture fx,
  List<Frame> frames,
  String who, {
  required int taker,
  required List<int> granted,
  required int next,
  required int rolledSeq,
}) {
  fx.eq(
      typesOf(frames),
      <String>[
        'moved',
        'sixes_granted',
        'turn_passed',
        'turn',
      ],
      'a taken release: the frame order seen by $who');
  final Map<String, Object?> m = dataOf(frames[0]);
  fx.eq(m['seat'], taker, '$who: moved.seat');
  fx.eq(m['from'], -1, '$who: moved.from');
  fx.eq(m['to'], 0, '$who: moved.to');
  fx.eq(m['captured'], <Object?>[], '$who: moved.captured');
  fx.eq(m['extra_roll'], false, '$who: moved.extra_roll');
  fx.eq(m['release'], true, '$who: moved.release');
  fx.absent(m, 'face', '$who: the moved frame of a release');
  fx.eq(m['seq'], rolledSeq + 1, '$who: moved.seq follows rolled.seq');
  final Map<String, Object?> g = dataOf(frames[1]);
  fx.eq(g['seats'], granted, '$who: sixes_granted.seats, ascending');
  fx.ok(g['seq'] is int && (g['seq']! as int) > (m['seq']! as int),
      '$who: sixes_granted.seq is after moved.seq', g);
  final Map<String, Object?> p = dataOf(frames[2]);
  fx.eq(p['seat'], taker, '$who: turn_passed.seat');
  fx.eq(p['reason'], 'released', '$who: turn_passed.reason');
  final Map<String, Object?> turn = dataOf(frames[3]);
  fx.eq(turn['seat'], next, '$who: turn.seat is the next playing seat');
  fx.eq(turn['phase'], 'await_roll', '$who: turn.phase');
  fx.ok(turn['seq'] is int && (turn['seq']! as int) > (g['seq']! as int),
      '$who: turn.seq is after sixes_granted.seq', turn);
  return frames;
}

void main() {
  // =========================================================================
  // Rule 1: the switch
  // =========================================================================
  group('rule 1: the switch, in process', () {
    test(
        'W1: a 2026-12 room: rules.ruleset, banked 0 and drought 0 on every '
        'seat, engine config sharedRelease on over yardRelease and playOut',
        () async {
      await withFixture('W1 2026-12 room', (Fixture fx) async {
        final Table t = await openTable(fx, players: 2);
        final Map<String, Object?> lobby = dataOf(t.createFrame);
        fx.eq((lobby['rules']! as Map<String, Object?>)['ruleset'], v12,
            'snapshot rules.ruleset');
        for (final Object? s in lobby['seats']! as List<Object?>) {
          final Map<String, Object?> seat = s! as Map<String, Object?>;
          fx.eq(seat['banked'], 0, 'seat ${seat['seat']} banked in the lobby');
          fx.eq(seat['drought'], 0, 'seat ${seat['seat']} drought');
        }
        await startGame(t);
        final engine.RulesConfig r = t.room.game!.config.rules;
        fx.eq(
          <bool>[
            r.rollQueue,
            r.homeBonus,
            r.yardRelease,
            r.playOut,
            r.sharedRelease
          ],
          <bool>[true, true, true, true, true],
          'engine config under 2026-12 plays everything 2026-11 plays and '
          'has sharedRelease on',
        );
        final Map<String, Object?> snap = await resume(t, 2);
        fx.eq((snap['rules']! as Map<String, Object?>)['ruleset'], v12,
            'resume snapshot rules.ruleset');
        for (final Object? s in snap['seats']! as List<Object?>) {
          final int banked = (s! as Map<String, Object?>)['banked']! as int;
          fx.ok(banked >= 0 && banked <= 3, 'banked is an integer 0..3', s);
        }
      }, ruleset: v12);
    });

    test('W2: a client cannot pick 2026-12: rules.ruleset is BAD_FIELD',
        () async {
      await withFixture('W2 client picks 2026-12', (Fixture fx) async {
        final WireTestClient c = await fx.connect();
        fx.send(c, 'create_room', <String, Object?>{
          'name': 'Host',
          'players': 2,
          'rules': <String, Object?>{'ruleset': v12},
        });
        final Frame f = await c.next();
        fx.eq(codeOf(fx, f, 'create_room with rules.ruleset'), 'BAD_FIELD',
            'error code');
      }, ruleset: v11);
    });

    for (final String ruleset in <String>[v11, v10]) {
      test(
          'W3: a $ruleset room is unaffected: no banked on any seat, '
          'sharedRelease off in the engine', () async {
        await withFixture('W3 $ruleset room unaffected', (Fixture fx) async {
          final Table t = await openTable(fx, players: 2);
          final Map<String, Object?> lobby = dataOf(t.createFrame);
          fx.eq((lobby['rules']! as Map<String, Object?>)['ruleset'],
              ruleset == v10 ? null : ruleset, 'rules.ruleset');
          for (final Object? s in lobby['seats']! as List<Object?>) {
            fx.absent(
                s! as Map<String, Object?>, 'banked', 'a $ruleset seat object');
          }
          await startGame(t);
          fx.eq(t.room.game!.config.rules.sharedRelease, false,
              'engine sharedRelease under $ruleset');
          final Map<String, Object?> snap = await resume(t, 2);
          for (final Object? s in snap['seats']! as List<Object?>) {
            fx.absent(s! as Map<String, Object?>, 'banked',
                'a $ruleset snapshot seat');
          }
        }, ruleset: ruleset);
      });
    }
  });

  group('rule 1: the switch, real process (RULESET in the environment)', () {
    test('P1: 2026-12 starts and creates a room of that ruleset', () async {
      final Directory root = await packageRoot();
      final int port = await freePort();
      final Process process = await Process.start(
        Platform.resolvedExecutable,
        <String>['run', 'bin/server.dart'],
        workingDirectory: root.path,
        environment: childEnvironment(<String, String>{
          'RULESET': v12,
          'PORT': '$port',
        }),
        includeParentEnvironment: false,
      );
      final StringBuffer out = StringBuffer();
      final StringBuffer err = StringBuffer();
      process.stdout.transform(utf8.decoder).listen(out.write);
      process.stderr.transform(utf8.decoder).listen(err.write);
      WireTestClient? client;
      try {
        bool exited = false;
        unawaited(process.exitCode.then((int _) => exited = true));
        final DateTime deadline =
            DateTime.now().add(const Duration(seconds: 90));
        while (!await isListening(port)) {
          if (exited || DateTime.now().isAfter(deadline)) {
            fail('RULESET=2026-12 PORT=$port: the server did not come up '
                '(exited=$exited). stderr: $err stdout: $out');
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        client = await WireTestClient.connect(
          Uri(scheme: 'ws', host: '127.0.0.1', port: port, path: '/'),
        );
        client.send('create_room', <String, Object?>{
          'name': 'Proc',
          'players': 2,
        });
        await client.next();
        final Frame room = await client.next();
        expect(room['t'], 'room',
            reason: 'RULESET=2026-12: create_room answered ${room['t']}: '
                '${room['d']}');
        final Map<String, Object?> rules =
            dataOf(room)['rules']! as Map<String, Object?>;
        expect(rules['ruleset'], v12,
            reason: 'RULESET=2026-12 PORT=$port: rules.ruleset in the '
                'snapshot; got $rules');
      } finally {
        await client?.close();
        process.kill(ProcessSignal.sigterm);
        await process.exitCode.timeout(const Duration(seconds: 20),
            onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return process.exitCode;
        });
      }
    }, timeout: const Timeout(Duration(seconds: 240)));

    test('P2: a value that is not 2026-10, 2026-11 or 2026-12 stops the start',
        () async {
      final Directory root = await packageRoot();
      for (final String bad in <String>['2026-13', '2026-12x', '2026-1']) {
        final int port = await freePort();
        final Process process = await Process.start(
          Platform.resolvedExecutable,
          <String>['run', 'bin/server.dart'],
          workingDirectory: root.path,
          environment: childEnvironment(<String, String>{
            'RULESET': bad,
            'PORT': '$port',
          }),
          includeParentEnvironment: false,
        );
        final Future<String> err =
            process.stderr.transform(utf8.decoder).join();
        final Future<String> out =
            process.stdout.transform(utf8.decoder).join();
        int? code;
        try {
          code = await process.exitCode.timeout(const Duration(seconds: 90));
        } on TimeoutException {
          process.kill(ProcessSignal.sigkill);
          fail('RULESET="$bad" PORT=$port: bin/server.dart did not exit '
              'within 90 s; section 30 rule 1 says any other value still '
              'stops the server at start');
        }
        final String errText = await err;
        final String outText = await out;
        expect(code, isNot(0),
            reason: 'RULESET="$bad" PORT=$port: expected a non-zero exit, '
                'got $code. stderr: $errText stdout: $outText');
        expect(errText, contains('RULESET'),
            reason: 'RULESET="$bad" PORT=$port: a line on stderr naming the '
                'variable. stderr: "$errText"');
        expect(await isListening(port), isFalse,
            reason: 'RULESET="$bad" PORT=$port: the port must never open');
      }
    }, timeout: const Timeout(Duration(seconds: 420)));
  });

  // =========================================================================
  // Rule 2: the offer
  // =========================================================================
  group('rule 2: the offer', () {
    test(
        'O1: ten non-6 rolls with every token in the yard: rolled release '
        'true offer true, legal the releasable tokens, queue the drawn face, '
        'no legal_by_face; the snapshot turn carries release and offer',
        () async {
      final Steer steer = Steer.noSix(19);
      await withFixture('O1 ten rolls to an offer', (Fixture fx) async {
        final Table t = await openTable(fx, players: 2, seeds: true);
        await startGame(t);
        final Map<int, List<Frame>> frames = await playToOffer(t);
        for (final int seat in <int>[0, 2]) {
          fx.eq(
              typesOf(frames[seat]!),
              <String>['rolled'],
              'roll 19, the tenth for seat 0: an offer leaves the turn '
              'waiting, so one rolled and nothing after it (seat $seat)');
        }
        final Map<String, Object?> rolled = dataOf(frames[0]!.single);
        final int face = rolled['value']! as int;
        fx.ok(face >= 1 && face <= 5, 'the drawn face is not a 6', rolled);
        fx.eq(rolled['k'], 19, 'k of the offering roll');
        fx.eq(rolled['release'], true, 'rolled.release');
        fx.eq(rolled['offer'], true, 'rolled.offer');
        fx.eq(rolled['legal'], <int>[0, 1, 2, 3],
            'legal is the releasable tokens, ascending');
        fx.eq(rolled['queue'], <int>[face], 'queue holds the drawn face');
        fx.absent(rolled, 'legal_by_face', 'an offering roll');
        fx.eq(rolled['deadline_ms'], 45000, 'a full segment starts');

        fx.clock.advance(const Duration(seconds: 5));
        final Map<String, Object?> snap = await resume(t, 2);
        final Map<String, Object?> turn = snap['turn']! as Map<String, Object?>;
        fx.eq(turn['seat'], 0, 'snapshot turn.seat');
        fx.eq(turn['phase'], 'await_move', 'snapshot turn.phase');
        fx.eq(turn['release'], true, 'snapshot turn.release');
        fx.eq(turn['offer'], true, 'snapshot turn.offer');
        fx.eq(turn['legal'], <int>[0, 1, 2, 3], 'snapshot turn.legal');
        fx.eq(turn['queue'], <int>[face], 'snapshot turn.queue');
        fx.absent(turn, 'value', 'the snapshot turn of an offer');
        fx.absent(turn, 'legal_by_face', 'the snapshot turn of an offer');
        fx.eq(turn['deadline_ms'], 40000,
            'the segment restarted on the offering rolled, 5 s ago');
      }, ruleset: v12, steer: steer);
    });

    test(
        'O2: while an offer is pending: roll is WRONG_PHASE, a move with a '
        'face is ILLEGAL_MOVE, a token that cannot be released is '
        'ILLEGAL_MOVE, and none of them changes the offer', () async {
      final Steer steer = Steer.faces(<int>[3]);
      await withFixture('O2 bad answers to an offer', (Fixture fx) async {
        final Table t = await openTable(fx, players: 2, seeds: true);
        await startGame(t);
        final Map<int, List<Frame>> offer = await rollToOffer(t);
        final Map<String, Object?> rolled = dataOf(offer[0]!.single);
        fx.eq(rolled['offer'], true, 'setup: the roll offered a release');
        final int face = rolled['value']! as int;

        for (final int bad in <int>[face, face == 1 ? 2 : 1, 6, 0, -1, 9]) {
          final Map<int, List<Frame>> r = await t
              .step(0, 'move', <String, Object?>{'token': 0, 'face': bad});
          expectError(fx, r[0]!, 'ILLEGAL_MOVE',
              'move with face $bad while a release is offered');
          fx.eq(r[2]!, <Frame>[], 'a rejected move tells nobody else');
        }
        final Map<int, List<Frame>> wrong =
            await t.step(0, 'roll', <String, Object?>{});
        expectError(fx, wrong[0]!, 'WRONG_PHASE', 'roll while offered');
        fx.eq(wrong[2]!, <Frame>[], 'a rejected roll tells nobody else');

        // Token 0 leaves the yard in the room's state; it is no longer
        // releasable, so naming it is ILLEGAL_MOVE and 1..3 still are.
        force(t, tokens: <int, List<int>>{
          0: <int>[5, -1, -1, -1],
        });
        final Map<int, List<Frame>> notReleasable =
            await t.step(0, 'move', <String, Object?>{'token': 0});
        expectError(fx, notReleasable[0]!, 'ILLEGAL_MOVE',
            'move of a token that cannot be released');
        final Map<int, List<Frame>> moved =
            await t.step(0, 'move', <String, Object?>{'token': 1});
        fx.eq(
            typesOf(moved[2]!),
            <String>['moved', 'sixes_granted', 'turn_passed', 'turn'],
            'after every rejection the offer was still there to take');
      }, ruleset: v12, steer: steer);
    });
  });

  // =========================================================================
  // Rule 3: taking it
  // =========================================================================
  group('rule 3: taking the release', () {
    test(
        'T1: move without face: moved, sixes_granted, turn_passed released, '
        'turn with banked 1 for the other seat; the queued face is not '
        'offered again; the taker does not roll again', () async {
      final Steer steer = Steer.faces(<int>[3]);
      await withFixture('T1 take, two seats', (Fixture fx) async {
        final Table t = await openTable(fx, players: 2, seeds: true);
        await startGame(t);
        final Map<int, List<Frame>> offer = await rollToOffer(t);
        final Map<String, Object?> rolled = dataOf(offer[0]!.single);
        final int rolledSeq = rolled['seq']! as int;

        final String id =
            fx.send(t.c(0), 'move', <String, Object?>{'token': 2});
        final Map<int, List<Frame>> r = await t.syncAll(first: 0);
        for (final int seat in <int>[0, 2]) {
          expectTakeFrames(fx, r[seat]!, 'seat $seat',
              taker: 0, granted: <int>[2], next: 2, rolledSeq: rolledSeq);
        }
        expectReEchoed(fx, r, 0, id, 'moved');
        final Map<String, Object?> m0 = dataOf(r[0]![0]);
        fx.eq(m0['token'], 2, 'moved.token is the chosen token');
        final Map<String, Object?> turn = dataOf(r[2]!.last);
        fx.eq(turn['banked'], 1, 'turn.banked for the granted seat');
        fx.eq(turn['queue'], <int>[6],
            'the banked six is queued; the drawn face is not offered again');
        fx.absent(turn, 'release', 'the next turn');
        fx.absent(turn, 'offer', 'the next turn');
        fx.eq(turn['deadline_ms'], 45000, 'a full segment for the next seat');

        // The taker does not roll again.
        final Map<int, List<Frame>> again =
            await t.step(0, 'roll', <String, Object?>{});
        expectError(fx, again[0]!, 'NOT_YOUR_TURN', 'the taker rolls again');

        // Snapshots: the grant is held on seat 2, the taker holds none, and
        // the token is out on the entry square.
        final Map<String, Object?> snap = await resume(t, 0);
        fx.eq(seatObject(snap, 2)['banked'], 0,
            'seat 2 banked: its turn has begun, the six is in the queue');
        fx.eq(seatObject(snap, 0)['banked'], 0, 'seat 0 banked');
        final Map<String, Object?> st = snap['turn']! as Map<String, Object?>;
        fx.eq(st['seat'], 2, 'snapshot turn.seat');
        fx.eq(st['phase'], 'await_roll', 'snapshot turn.phase');
        fx.absent(st, 'banked', 'the snapshot turn object');
        fx.eq(st['queue'], <int>[6], 'snapshot turn.queue');
        fx.eq(t.room.game!.tokens[0], <int>[-1, -1, 0, -1],
            'the chosen token alone is out, on the entry square');
      }, ruleset: v12, steer: steer);
    });

    test(
        'T2: a replayed take, a decline after the take and a decline_release '
        'from the other seat are all NOT_YOUR_TURN and change nothing',
        () async {
      final Steer steer = Steer.faces(<int>[3]);
      await withFixture('T2 replay after take', (Fixture fx) async {
        final Table t = await openTable(fx, players: 2, seeds: true);
        await startGame(t);
        await rollToOffer(t);
        await t.step(0, 'move', <String, Object?>{'token': 0});
        final Map<int, List<Frame>> replay =
            await t.step(0, 'move', <String, Object?>{'token': 1});
        expectError(fx, replay[0]!, 'NOT_YOUR_TURN', 'replayed take');
        final Map<int, List<Frame>> late =
            await t.step(0, 'decline_release', <String, Object?>{});
        expectError(fx, late[0]!, 'NOT_YOUR_TURN', 'decline after the take');
        fx.eq(late[2]!, <Frame>[], 'a rejection tells nobody else');
        // Seat 2 is on turn with a banked six and no offer.
        final Map<int, List<Frame>> noOffer =
            await t.step(2, 'decline_release', <String, Object?>{});
        expectError(fx, noOffer[2]!, 'WRONG_PHASE',
            'decline_release by the seat on turn, no offer pending');
        fx.eq(t.room.game!.tokens[0], <int>[0, -1, -1, -1],
            'one token out and no more, whatever was replayed');
      }, ruleset: v12, steer: steer);
    });

    test(
        'T3: the seat rolls first (move in await_roll is WRONG_PHASE), then '
        'spends the banked six with move face 6 on a release: no rolled '
        'frame for the six, no k, no extra roll', () async {
      final Steer steer = Steer.faces(<int>[3, 4]);
      await withFixture('T3 banked six spent', (Fixture fx) async {
        final Table t = await openTable(fx, players: 2, seeds: true);
        await startGame(t);
        await rollToOffer(t);
        await t.step(0, 'move', <String, Object?>{'token': 0});
        fx.clock.advance(const Duration(seconds: 2));

        // Rule 11q: the roll comes first. A move before it is refused and
        // changes nothing.
        final Map<int, List<Frame>> early =
            await t.step(2, 'move', <String, Object?>{'token': 0, 'face': 6});
        expectError(fx, early[2]!, 'WRONG_PHASE',
            'move with the banked six before the seat has rolled');
        fx.eq(early[0]!, <Frame>[], 'a rejected move tells nobody else');

        // The seat's own first roll is roll k=2: the banked six consumed no
        // fair draw. The banked six leads the queue, the rolled 4 follows.
        final Map<int, List<Frame>> roll =
            await t.step(2, 'roll', <String, Object?>{});
        final Map<String, Object?> rolled = dataOf(only(fx, roll[2]!, 'rolled',
            'the seat\'s own roll with a banked six queued'));
        fx.eq(rolled['k'], 2, 'rolled.k: the first roll after the take is k=2');
        fx.eq(rolled['value'], 4, 'rolled.value: the second steered face');
        fx.eq(rolled['queue'], <int>[6, 4], 'queue: banked six, then the 4');
        fx.eq(typesOf(roll[2]!), <String>['rolled'],
            'a roll that leaves a move pending is one rolled frame');

        final String id =
            fx.send(t.c(2), 'move', <String, Object?>{'token': 0, 'face': 6});
        final Map<int, List<Frame>> r = await t.syncAll(first: 2);
        for (final int seat in <int>[0, 2]) {
          fx.eq(
              typesOf(r[seat]!),
              <String>['moved', 'turn'],
              'the banked six spent on a release, then the 4 is still to '
              'spend by the same seat (seat $seat)');
        }
        final Map<String, Object?> m = dataOf(r[2]![0]);
        fx.eq(m['seat'], 2, 'moved.seat');
        fx.eq(m['token'], 0, 'moved.token');
        fx.eq(m['from'], -1, 'moved.from');
        fx.eq(m['to'], 0, 'moved.to');
        fx.eq(m['face'], 6, 'moved.face');
        fx.eq(m['extra_roll'], false, 'a spent banked six owes no roll');
        fx.absent(m, 'k', 'a banked six is not a roll');
        expectReEchoed(fx, r, 2, id, 'moved');
        final Map<String, Object?> turn = dataOf(r[2]![1]);
        fx.eq(turn['seat'], 2, 'turn.seat: same seat, a face is left');
        fx.eq(turn['phase'], 'await_move', 'turn.phase');
        fx.eq(turn['queue'], <int>[4], 'turn.queue: the rolled 4 remains');
      }, ruleset: v12, steer: steer);
    });

    test(
        'T4: the grant needs a connection: the other seat is granted a six '
        'although its socket is closed, and finds it on resume', () async {
      final Steer steer = Steer.faces(<int>[3]);
      await withFixture('T4 grant to a disconnected seat', (Fixture fx) async {
        final Table t = await openTable(fx, players: 2, seeds: true);
        await startGame(t);
        await rollToOffer(t);
        await dropMany(t, <int>[2]);
        final Map<int, List<Frame>> r =
            await t.step(0, 'move', <String, Object?>{'token': 0});
        final List<Frame> seen = without(r[0]!, 'presence');
        fx.eq(
            typesOf(seen),
            <String>['moved', 'sixes_granted', 'turn_passed', 'turn'],
            'the taker sees the whole take');
        fx.eq(dataOf(seen[1])['seats'], <int>[2],
            'the disconnected seat is granted too');
        final Map<String, Object?> snap = await resume(t, 2);
        fx.eq(seatObject(snap, 2)['banked'], 0,
            'banked on resume: its turn has begun, the six is in the queue');
        final Map<String, Object?> st = snap['turn']! as Map<String, Object?>;
        fx.eq(st['seat'], 2, 'snapshot turn.seat');
        fx.eq(st['queue'], <int>[6], 'snapshot turn.queue');
        fx.absent(st, 'banked', 'the snapshot turn object');
      }, ruleset: v12, steer: steer);
    });
  });

  // =========================================================================
  // Rule 4: declining it
  // =========================================================================
  group('rule 4: declining the release', () {
    test(
        'D1: decline_release: release_declined (re on the declining socket '
        'only), turn_passed no_legal_move, turn for the next seat; nothing '
        'comes out and nothing is banked; the drought is 9', () async {
      final Steer steer = Steer.faces(<int>[3]);
      await withFixture('D1 decline, two seats', (Fixture fx) async {
        final Table t = await openTable(fx, players: 2, seeds: true);
        await startGame(t);
        final Map<int, List<Frame>> offer = await rollToOffer(t);
        final int rolledSeq = dataOf(offer[0]!.single)['seq']! as int;

        final String id =
            fx.send(t.c(0), 'decline_release', <String, Object?>{});
        final Map<int, List<Frame>> r = await t.syncAll(first: 0);
        for (final int seat in <int>[0, 2]) {
          fx.eq(
              typesOf(r[seat]!),
              <String>['release_declined', 'turn_passed', 'turn'],
              'the decline, then the pass (seat $seat)');
          final Map<String, Object?> d = dataOf(r[seat]![0]);
          fx.eq(d['seat'], 0, 'release_declined.seat');
          fx.eq(d['seq'], rolledSeq + 1, 'release_declined.seq');
          fx.eq(dataOf(r[seat]![1])['seat'], 0, 'turn_passed.seat');
          fx.eq(dataOf(r[seat]![1])['reason'], 'no_legal_move',
              'turn_passed.reason');
          final Map<String, Object?> turn = dataOf(r[seat]![2]);
          fx.eq(turn['seat'], 2, 'turn.seat');
          fx.eq(turn['phase'], 'await_roll', 'turn.phase');
          fx.absent(turn, 'banked', 'the turn after a decline');
          fx.absent(turn, 'offer', 'the turn after a decline');
          fx.absent(turn, 'release', 'the turn after a decline');
        }
        expectReEchoed(fx, r, 0, id, 'release_declined');
        fx.ok(
            !r.values.any((List<Frame> f) => f.any(
                (Frame x) => x['t'] == 'sixes_granted' || x['t'] == 'moved')),
            'a decline grants nothing and moves nothing');

        final Map<String, Object?> snap = await resume(t, 0);
        for (final int seat in <int>[0, 2]) {
          fx.eq(seatObject(snap, seat)['banked'], 0, 'seat $seat banked');
        }
        fx.eq(seatObject(snap, 0)['drought'], 9, 'the drought is 9');
        fx.eq(t.room.game!.tokens[0], <int>[-1, -1, -1, -1],
            'every token of the decliner is still in the yard');
        final Map<String, Object?> st = snap['turn']! as Map<String, Object?>;
        fx.eq(st['seat'], 2, 'snapshot turn.seat');
        fx.absent(st, 'offer', 'the snapshot after a decline');
      }, ruleset: v12, steer: steer);
    });

    test(
        'D2: the drought is 9 after a decline, so the next non-6 offers '
        'again', () async {
      // Rolls: 1 seat 0 face 3 (offer, declined), 2 seat 2 face 4 (ordinary
      // pass), 3 seat 0 face 5: its tenth non-6 counting from the 9 the
      // decline left.
      final Steer steer = Steer.faces(<int>[3, 4, 5]);
      await withFixture('D2 offer repeats after decline', (Fixture fx) async {
        final Table t = await openTable(fx, players: 2, seeds: true);
        await startGame(t);
        await rollToOffer(t);
        await t.step(0, 'decline_release', <String, Object?>{});
        final Map<int, List<Frame>> two =
            await t.step(2, 'roll', <String, Object?>{});
        fx.eq(typesOf(two[0]!), <String>['rolled', 'turn_passed', 'turn'],
            'seat 2 rolls a 4 with every token home: a pass');
        final Map<int, List<Frame>> three =
            await t.step(0, 'roll', <String, Object?>{});
        final Map<String, Object?> rolled =
            dataOf(only(fx, three[0]!, 'rolled', 'seat 0\'s next roll'));
        fx.eq(rolled['k'], 3, 'k');
        fx.eq(rolled['value'], 5, 'the steered face');
        fx.eq(rolled['release'], true, 'the offer repeats: release');
        fx.eq(rolled['offer'], true, 'the offer repeats: offer');
        fx.eq(rolled['legal'], <int>[0, 1, 2, 3], 'legal');
        fx.eq(typesOf(three[0]!), <String>['rolled'], 'one frame');
      }, ruleset: v12, steer: steer);
    });

    test('D3: a 6 after a decline sets the drought to 0 (rule 10r)', () async {
      final Steer steer = Steer.faces(<int>[3, 6]);
      await withFixture('D3 six after decline', (Fixture fx) async {
        final Table t = await openTable(fx, players: 2, seeds: true);
        await startGame(t);
        await rollToOffer(t);
        await t.step(0, 'decline_release', <String, Object?>{});
        // Hand the turn back to seat 0 without disturbing its drought.
        force(t, currentSeat: 0, phase: 'awaitRoll', queue: <int>[]);
        final Map<int, List<Frame>> r =
            await t.step(0, 'roll', <String, Object?>{});
        final Map<String, Object?> rolled =
            dataOf(only(fx, r[0]!, 'rolled', 'the six'));
        fx.eq(rolled['value'], 6, 'the steered face');
        fx.absent(rolled, 'offer', 'a 6 is not an offer');
        final Map<String, Object?> snap = await resume(t, 2);
        fx.eq(seatObject(snap, 0)['drought'], 0, 'drought after a 6');
      }, ruleset: v12, steer: steer);
    });

    test(
        'D4: decline_release errors: WRONG_PHASE with no offer, '
        'NOT_YOUR_TURN out of turn (whatever the phase), BAD_FIELD on a '
        'payload, and each changes nothing', () async {
      final Steer steer = Steer.faces(<int>[3]);
      await withFixture('D4 decline errors', (Fixture fx) async {
        final Table t = await openTable(fx, players: 2, seeds: true);
        await startGame(t);

        // Seat 0 on turn, awaiting a roll: no offer pending.
        final Map<int, List<Frame>> noOffer =
            await t.step(0, 'decline_release', <String, Object?>{});
        expectError(fx, noOffer[0]!, 'WRONG_PHASE', 'decline with no offer');
        fx.eq(noOffer[2]!, <Frame>[], 'nobody else is told');
        // Seat 2 out of turn: NOT_YOUR_TURN precedes the phase check.
        final Map<int, List<Frame>> outOfTurn =
            await t.step(2, 'decline_release', <String, Object?>{});
        expectError(fx, outOfTurn[2]!, 'NOT_YOUR_TURN',
            'decline out of turn, no offer');

        await rollToOffer(t);
        // Seat 2 out of turn with an offer pending for seat 0.
        final Map<int, List<Frame>> outOfTurn2 =
            await t.step(2, 'decline_release', <String, Object?>{});
        expectError(fx, outOfTurn2[2]!, 'NOT_YOUR_TURN',
            'decline by another seat while seat 0 holds the offer');
        fx.eq(outOfTurn2[0]!, <Frame>[], 'the offerer is not disturbed');
        // A payload the message does not have.
        final Map<int, List<Frame>> junk =
            await t.step(0, 'decline_release', <String, Object?>{'token': 1});
        expectError(fx, junk[0]!, 'BAD_FIELD', 'decline_release with a field');

        // The offer is intact after all of that: it can still be taken.
        final Map<int, List<Frame>> take =
            await t.step(0, 'move', <String, Object?>{'token': 3});
        fx.eq(
            typesOf(take[0]!),
            <String>['moved', 'sixes_granted', 'turn_passed', 'turn'],
            'the offer survived every rejection');
      }, ruleset: v12, steer: steer);
    });

    test(
        'D5: decline_release walks the roll ladder: a socket in no room, a '
        'lobby, a finished room', () async {
      await withFixture('D5 decline ladder', (Fixture fx) async {
        // No room: same answer as roll.
        final WireTestClient stray = await fx.connect();
        fx.send(stray, 'roll', <String, Object?>{});
        final String rollNoRoom =
            codeOf(fx, await stray.next(), 'roll, no room');
        fx.send(stray, 'decline_release', <String, Object?>{});
        fx.eq(codeOf(fx, await stray.next(), 'decline_release, no room'),
            rollNoRoom, 'decline_release in no room answers as roll does');
        fx.eq(rollNoRoom, 'BAD_SEAT_TOKEN', 'section 7: no seat held');

        // LOBBY: same answer as roll (the section names ROOM_STARTED in its
        // list while section 12.1 says WRONG_PHASE for roll in a lobby; the
        // section says "the same checks and order as roll", so this pins
        // equality and reports the pair).
        final Table lobby = await openTable(fx, players: 2);
        final Map<int, List<Frame>> lr =
            await lobby.step(0, 'roll', <String, Object?>{});
        final String rollLobby = codeOf(fx, lr[0]!.single, 'roll in a lobby');
        final Map<int, List<Frame>> ld =
            await lobby.step(0, 'decline_release', <String, Object?>{});
        fx.eq(codeOf(fx, ld[0]!.single, 'decline_release in a lobby'),
            rollLobby, 'decline_release in a lobby answers as roll does');

        // FINISHED: GAME_OVER.
        await startGame(lobby);
        forceFinishingMove(lobby, 0);
        final Map<int, List<Frame>> end =
            await lobby.step(0, 'move', <String, Object?>{'token': 3});
        fx.ok(end[2]!.any((Frame f) => f['t'] == 'game_over'),
            'setup: the finishing move ends the game', typesOf(end[2]!));
        for (final int seat in <int>[0, 2]) {
          final Map<int, List<Frame>> r =
              await lobby.step(seat, 'decline_release', <String, Object?>{});
          expectError(fx, r[seat]!, 'GAME_OVER',
              'decline_release by seat $seat in a finished room');
        }
      }, ruleset: v12);
    });
  });

  // =========================================================================
  // Rule 2: the lapse
  // =========================================================================
  group('rule 2: the lapse', () {
    test(
        'L1: no token can be released: rolled release true legal [] and no '
        'offer, then turn_passed no_legal_move and turn; nothing is banked',
        () async {
      final Steer steer = Steer.faces(<int>[4]);
      await withFixture('L1 lapse', (Fixture fx) async {
        final Table t = await openTable(fx, players: 2, seeds: true);
        await startGame(t);
        // Seat 2 holds a block on seat 0's entry square (progress 26 is
        // square 0); the engine honours blocks only when the toggle is on,
        // and a room made by create_room has it off, so the forced position
        // turns it on.
        force(
          t,
          drought: <int>[9, 0, 0, 0],
          blocks: true,
          tokens: <int, List<int>>{
            2: <int>[26, 26, -1, -1],
          },
        );
        final Map<int, List<Frame>> r =
            await t.step(0, 'roll', <String, Object?>{});
        for (final int seat in <int>[0, 2]) {
          fx.eq(typesOf(r[seat]!), <String>['rolled', 'turn_passed', 'turn'],
              'a lapse passes the turn like any pass (seat $seat)');
        }
        final Map<String, Object?> rolled = dataOf(r[0]!.first);
        fx.eq(rolled['release'], true, 'rolled.release on a lapse');
        fx.eq(rolled['legal'], <int>[], 'rolled.legal on a lapse');
        fx.absent(rolled, 'offer', 'a lapse');
        fx.eq(rolled['value'], 4, 'the drawn face is still recorded');
        fx.eq(
            dataOf(r[0]![1])['reason'], 'no_legal_move', 'turn_passed.reason');
        fx.eq(dataOf(r[0]![1])['seat'], 0, 'turn_passed.seat');
        final Map<String, Object?> turn = dataOf(r[0]![2]);
        fx.eq(turn['seat'], 2, 'turn.seat');
        fx.absent(turn, 'banked', 'the turn after a lapse');
        fx.ok(
            !r.values.any((List<Frame> f) =>
                f.any((Frame x) => x['t'] == 'sixes_granted')),
            'a lapse banks nothing: no sixes_granted');
        final Map<String, Object?> snap = await resume(t, 2);
        for (final int seat in <int>[0, 2]) {
          fx.eq(seatObject(snap, seat)['banked'], 0, 'seat $seat banked');
        }
        fx.eq(seatObject(snap, 0)['drought'], 0,
            'the drought starts again from 0 after a lapse');
        fx.absent(snap['turn']! as Map<String, Object?>, 'offer',
            'the snapshot after a lapse');
        // decline_release has nothing to answer.
        final Map<int, List<Frame>> d =
            await t.step(2, 'decline_release', <String, Object?>{});
        expectError(fx, d[2]!, 'WRONG_PHASE', 'decline after a lapse');
      }, ruleset: v12, steer: steer);
    });
  });

  // =========================================================================
  // Rule 6: the timer
  // =========================================================================
  group('rule 6: the timer', () {
    test(
        'M1: on expiry of an offer the server takes it on the lowest '
        'releasable token (moved by timer), then sixes_granted, '
        'turn_passed released, turn; 44 999 ms is too early; the timer never '
        'declines', () async {
      final Steer steer = Steer.faces(<int>[3]);
      await withFixture('M1 timer takes the offer', (Fixture fx) async {
        final Table t = await openTable(fx, players: 2, seeds: true);
        await startGame(t);
        fx.clock.advance(const Duration(seconds: 20));
        force(t, drought: <int>[9, 0, 0, 0]);
        // _force restarted the segment; take the 20 s back so the roll
        // really arrives late in a segment.
        t.room.turnSegmentStartedAt =
            fx.clock.now.subtract(const Duration(seconds: 20));
        final Map<int, List<Frame>> r =
            await t.step(0, 'roll', <String, Object?>{});
        final Map<String, Object?> rolled = dataOf(r[0]!.single);
        fx.eq(rolled['offer'], true, 'setup: an offer');
        fx.eq(rolled['deadline_ms'], 45000,
            'the segment restarts on the offering rolled (20 s had run)');

        fx.clock.advance(const Duration(milliseconds: 44999));
        fx.server.runTurnExpiryOnce();
        final List<Frame> early = <Frame>[
          for (final List<Frame> f in (await t.syncAll()).values) ...f
        ];
        fx.eq(early, <Frame>[], '44 999 ms into the segment: no action');

        fx.clock.advance(const Duration(milliseconds: 1));
        fx.server.runTurnExpiryOnce();
        final Map<int, List<Frame>> after = await t.syncAll();
        for (final int seat in <int>[0, 2]) {
          expectTakeFrames(fx, after[seat]!, 'seat $seat',
              taker: 0,
              granted: <int>[2],
              next: 2,
              rolledSeq: (rolled['seq']! as int));
          final Map<String, Object?> m = dataOf(after[seat]![0]);
          fx.eq(m['by'], 'timer', 'moved.by');
          fx.eq(m['token'], 0, 'the lowest releasable token');
          fx.ok(!after[seat]![0].containsKey('re'),
              'a timer step answers no request', after[seat]![0]);
          fx.absent(dataOf(after[seat]![2]), 'by', 'turn_passed');
          fx.absent(dataOf(after[seat]![3]), 'by', 'turn');
          fx.eq(dataOf(after[seat]![3])['banked'], 1, 'turn.banked');
        }
        fx.ok(
            !after.values.any((List<Frame> f) =>
                f.any((Frame x) => x['t'] == 'release_declined')),
            'the timer never declines');
      }, ruleset: v12, steer: steer);
    });

    test('M2: the timer takes the lowest of the tokens that can be released',
        () async {
      final Steer steer = Steer.faces(<int>[3]);
      await withFixture('M2 timer lowest releasable', (Fixture fx) async {
        final Table t = await openTable(fx, players: 2, seeds: true);
        await startGame(t);
        await rollToOffer(t);
        force(t, tokens: <int, List<int>>{
          0: <int>[5, -1, -1, -1],
        });
        fx.clock.advance(const Duration(seconds: 45));
        fx.server.runTurnExpiryOnce();
        final Map<int, List<Frame>> after = await t.syncAll();
        final Frame moved = only(fx, after[2]!, 'moved', 'the timer step');
        fx.eq(dataOf(moved)['token'], 1, 'token 0 is on the board, so 1');
        fx.eq(dataOf(moved)['by'], 'timer', 'moved.by');
      }, ruleset: v12, steer: steer);
    });

    test(
        'M3: the offerer closes its socket with the offer pending: the '
        'timer still takes it, and the offerer resumes into the right '
        'snapshot', () async {
      final Steer steer = Steer.faces(<int>[3]);
      await withFixture('M3 offerer drops', (Fixture fx) async {
        final Table t = await openTable(fx, players: 2, seeds: true);
        await startGame(t);
        await rollToOffer(t);
        await dropMany(t, <int>[0]);
        fx.clock.advance(const Duration(seconds: 45));
        fx.server.runTurnExpiryOnce();
        final Map<int, List<Frame>> after = await t.syncAll();
        fx.eq(
            typesOf(without(after[2]!, 'presence')),
            <String>['moved', 'sixes_granted', 'turn_passed', 'turn'],
            'the timer took the offer of a seat that is gone');
        final Map<String, Object?> snap = await resume(t, 0);
        final Map<String, Object?> st = snap['turn']! as Map<String, Object?>;
        fx.eq(st['seat'], 2, 'snapshot turn.seat after the take');
        fx.eq(seatObject(snap, 2)['banked'], 0,
            'seat 2 banked: its turn has begun, the six is in the queue');
        fx.absent(st, 'offer', 'the snapshot after the take');
      }, ruleset: v12, steer: steer);
    });

    test(
        'M4: the offerer drops and resumes with the offer pending: the '
        'snapshot still carries release and offer, and the take works',
        () async {
      final Steer steer = Steer.faces(<int>[3]);
      await withFixture('M4 offerer resumes into the offer',
          (Fixture fx) async {
        final Table t = await openTable(fx, players: 2, seeds: true);
        await startGame(t);
        await rollToOffer(t);
        await dropMany(t, <int>[0]);
        final Map<String, Object?> snap = await resume(t, 0);
        final Map<String, Object?> st = snap['turn']! as Map<String, Object?>;
        fx.eq(st['release'], true, 'snapshot turn.release');
        fx.eq(st['offer'], true, 'snapshot turn.offer');
        fx.eq(st['phase'], 'await_move', 'snapshot turn.phase');
        await t.syncAll();
        final Map<int, List<Frame>> take =
            await t.step(0, 'move', <String, Object?>{'token': 1});
        fx.eq(
            typesOf(without(take[2]!, 'presence')),
            <String>['moved', 'sixes_granted', 'turn_passed', 'turn'],
            'the resumed seat takes the offer');
      }, ruleset: v12, steer: steer);
    });
  });

  // =========================================================================
  // Rule 3 with three seats
  // =========================================================================
  group('rule 3: three seats', () {
    test(
        'S1: a take grants both other seats, ascending; the next seat holds '
        'the turn with banked 1, the third holds its six for later', () async {
      final Steer steer = Steer.faces(<int>[3], players: 3);
      await withFixture('S1 take, three seats', (Fixture fx) async {
        final Table t = await openTable(fx, players: 3, seeds: true);
        await startGame(t);
        final Map<int, List<Frame>> offer = await rollToOffer(t);
        final int rolledSeq = dataOf(offer[0]!.single)['seq']! as int;
        final Map<int, List<Frame>> r =
            await t.step(0, 'move', <String, Object?>{'token': 1});
        for (final int seat in <int>[0, 1, 2]) {
          expectTakeFrames(fx, r[seat]!, 'seat $seat',
              taker: 0, granted: <int>[1, 2], next: 1, rolledSeq: rolledSeq);
          fx.eq(dataOf(r[seat]!.last)['banked'], 1, 'turn.banked');
          fx.eq(dataOf(r[seat]!.last)['queue'], <int>[6], 'turn.queue');
        }
        final Map<String, Object?> snap = await resume(t, 2);
        fx.eq(
            <Object?>[
              for (final int s in <int>[0, 1, 2]) seatObject(snap, s)['banked']
            ],
            <int>[
              0,
              0,
              1
            ],
            'banked per seat: seat 1 holds the turn (its six is queued), '
            'seat 2 has not begun its turn');
      }, ruleset: v12, steer: steer);
    });

    test(
        'S2: two releases before a seat has played: its banked count is 2 '
        'and its turn queues two sixes', () async {
      final Steer steer = Steer.faces(<int>[3, 3], players: 3);
      await withFixture('S2 two grants stack', (Fixture fx) async {
        final Table t = await openTable(fx, players: 3, seeds: true);
        await startGame(t);
        await rollToOffer(t, seat: 0);
        await t.step(0, 'move', <String, Object?>{'token': 0});
        // Seat 1 holds a banked six and its own roll to make: its drought is
        // forced to 9 so that roll is its tenth.
        final Map<int, List<Frame>> roll = await rollToOffer(t, seat: 1);
        fx.eq(dataOf(only(fx, roll[1]!, 'rolled', 'seat 1 roll'))['offer'],
            true, 'seat 1 is offered a release');
        final Map<int, List<Frame>> take =
            await t.step(1, 'move', <String, Object?>{'token': 0});
        fx.eq(dataOf(ofType(take[1]!, 'sixes_granted').single)['seats'],
            <int>[0, 2], 'seat 1 grants the other two, ascending');
        final Map<String, Object?> turn = dataOf(take[2]!.last);
        fx.eq(turn['seat'], 2, 'turn.seat');
        fx.eq(turn['banked'], 2, 'seat 2 holds two banked sixes');
        fx.eq(turn['queue'], <int>[6, 6], 'both are queued');
        final Map<String, Object?> snap = await resume(t, 0);
        fx.eq(seatObject(snap, 2)['banked'], 0,
            'snapshot banked of seat 2: its turn has begun, both sixes queued');
        fx.eq(seatObject(snap, 0)['banked'], 1, 'snapshot banked of seat 0');
        fx.eq(seatObject(snap, 1)['banked'], 0, 'snapshot banked of seat 1');
      }, ruleset: v12, steer: steer);
    });

    test(
        'S3: a seat that finished is not granted: sixes_granted lists only '
        'the seat still playing, and the turn skips the finished seat',
        () async {
      final Steer steer = Steer.faces(<int>[3], players: 3);
      await withFixture('S3 finished seat not granted', (Fixture fx) async {
        final Table t = await openTable(fx, players: 3, seeds: true);
        await startGame(t);
        forceFinishingMove(t, 1);
        final Map<int, List<Frame>> fin =
            await t.step(1, 'move', <String, Object?>{'token': 3});
        fx.ok(fin[0]!.any((Frame f) => f['t'] == 'seat_finished'),
            'setup: seat 1 finished and the game goes on', typesOf(fin[0]!));
        fx.eq(dataOf(fin[0]!.last)['seat'], 2, 'setup: seat 2 is on turn');

        final Map<int, List<Frame>> offer = await rollToOffer(t, seat: 2);
        fx.eq(dataOf(only(fx, offer[2]!, 'rolled', 'seat 2 roll'))['offer'],
            true, 'seat 2 is offered a release');
        final Map<int, List<Frame>> r =
            await t.step(2, 'move', <String, Object?>{'token': 0});
        for (final int seat in <int>[0, 1, 2]) {
          fx.eq(
              typesOf(r[seat]!),
              <String>['moved', 'sixes_granted', 'turn_passed', 'turn'],
              'the take (seat $seat)');
          fx.eq(dataOf(r[seat]![1])['seats'], <int>[0],
              'only the playing seat 0 is granted (seat $seat view)');
          fx.eq(dataOf(r[seat]![3])['seat'], 0,
              'the finished seat 1 is skipped (seat $seat view)');
          fx.eq(dataOf(r[seat]![3])['banked'], 1, 'turn.banked');
        }
        final Map<String, Object?> snap = await resume(t, 0);
        fx.eq(seatObject(snap, 1)['banked'], 0, 'finished seat banked');
        fx.eq(seatObject(snap, 0)['banked'], 0,
            'seat 0 banked: its turn has begun, the six is in the queue');
      }, ruleset: v12, steer: steer);
    });

    test(
        'S4: a seat that left the game (retired) is not granted and its '
        'turn is skipped', () async {
      final Steer steer = Steer.faces(<int>[3], players: 3);
      await withFixture('S4 retired seat not granted', (Fixture fx) async {
        final Table t = await openTable(fx, players: 3, seeds: true);
        await startGame(t);
        await t.step(1, 'leave_room', <String, Object?>{});
        await rollToOffer(t, seat: 0);
        final Map<int, List<Frame>> r =
            await t.step(0, 'move', <String, Object?>{'token': 0});
        final Frame granted = only(fx, r[0]!, 'sixes_granted', 'the take');
        fx.eq(dataOf(granted)['seats'], <int>[2],
            'seat 1 retired: only seat 2 is granted');
        fx.eq(dataOf(r[0]!.last)['seat'], 2, 'the turn skips seat 1');
        fx.eq(dataOf(r[0]!.last)['banked'], 1, 'turn.banked');
      }, ruleset: v12, steer: steer);
    });

    test(
        'S5: both other seats close their sockets at once, then the take: '
        'both are still granted, each finds its six on resume', () async {
      final Steer steer = Steer.faces(<int>[3], players: 3);
      await withFixture('S5 both others disconnected', (Fixture fx) async {
        final Table t = await openTable(fx, players: 3, seeds: true);
        await startGame(t);
        await rollToOffer(t);
        await dropMany(t, <int>[1, 2]);
        final Map<int, List<Frame>> r =
            await t.step(0, 'move', <String, Object?>{'token': 0});
        fx.eq(
            typesOf(without(r[0]!, 'presence')),
            <String>['moved', 'sixes_granted', 'turn_passed', 'turn'],
            'the take with nobody else connected');
        fx.eq(dataOf(ofType(r[0]!, 'sixes_granted').single)['seats'],
            <int>[1, 2], 'both disconnected seats are granted');
        final Map<String, Object?> snap = await resume(t, 1);
        fx.eq(seatObject(snap, 1)['banked'], 0,
            'seat 1 banked on resume: its turn has begun');
        fx.eq(seatObject(snap, 2)['banked'], 1, 'seat 2 banked');
      }, ruleset: v12, steer: steer);
    });

    test(
        'S6: three seats, a decline: nothing granted, the next seat plays on '
        'with no banked key', () async {
      final Steer steer = Steer.faces(<int>[3], players: 3);
      await withFixture('S6 decline, three seats', (Fixture fx) async {
        final Table t = await openTable(fx, players: 3, seeds: true);
        await startGame(t);
        await rollToOffer(t);
        final Map<int, List<Frame>> r =
            await t.step(0, 'decline_release', <String, Object?>{});
        for (final int seat in <int>[0, 1, 2]) {
          fx.eq(
              typesOf(r[seat]!),
              <String>['release_declined', 'turn_passed', 'turn'],
              'the decline (seat $seat)');
          fx.eq(dataOf(r[seat]!.last)['seat'], 1, 'turn.seat');
          fx.absent(dataOf(r[seat]!.last), 'banked', 'turn after a decline');
        }
      }, ruleset: v12, steer: steer);
    });
  });

  // =========================================================================
  // 2026-11 and 2026-10 servers
  // =========================================================================
  group('older rulesets: no new keys, decline_release has nothing to answer',
      () {
    const List<String> newKeys = <String>[
      'offer',
      'banked',
      'declined',
      'grants',
    ];
    for (final String ruleset in <String>[v11, v10]) {
      test(
          'C1: a $ruleset server: the same scenario (ten non-6 rolls, take '
          'or play on) carries none of the new keys or frame types', () async {
        final Steer steer = Steer.faces(<int>[3]);
        await withFixture('C1 $ruleset frames', (Fixture fx) async {
          final Table t = await openTable(fx, players: 2, seeds: true);
          final List<Frame> seen = <Frame>[];
          seen.add(t.createFrame);
          await startGame(t);
          // v11 holds a drought and releases; v10 has neither, so the same
          // steered roll is an ordinary roll there.
          if (ruleset == v11) {
            force(t, drought: <int>[9, 0, 0, 0]);
          }
          final Map<int, List<Frame>> roll =
              await t.step(0, 'roll', <String, Object?>{});
          seen.addAll(roll.values.expand((List<Frame> f) => f));
          final Frame rolled = ofType(roll[0]!, 'rolled').single;
          if (ruleset == v11) {
            fx.eq(dataOf(rolled)['release'], true,
                '2026-11 still grants the release on the wire');
            final Map<int, List<Frame>> take =
                await t.step(0, 'move', <String, Object?>{'token': 0});
            seen.addAll(take.values.expand((List<Frame> f) => f));
            fx.eq(
                typesOf(take[2]!),
                <String>['moved', 'turn'],
                '2026-11 take: moved then the same seat in await_move, as '
                'section 28 rule 2 says');
          }
          final Map<String, Object?> snap = await resume(t, 2);
          seen.add(<String, Object?>{'t': 'room', 'd': snap});
          final Set<String> keys = allKeys(seen);
          for (final String key in newKeys) {
            fx.ok(!keys.contains(key),
                'no frame of a $ruleset room carries "$key"', keys.toList());
          }
          final Set<Object?> types = <Object?>{
            for (final Frame f in seen) f['t']
          };
          for (final String type in <String>[
            'sixes_granted',
            'release_declined'
          ]) {
            fx.ok(!types.contains(type), 'a $ruleset room never sends "$type"',
                types.toList());
          }
          for (final Frame f in seen) {
            if (f['t'] == 'turn_passed') {
              fx.ok(dataOf(f)['reason'] != 'released',
                  'a $ruleset room never passes with reason released', f);
            }
          }
        }, ruleset: ruleset, steer: steer);
      });

      test(
          'C2: a $ruleset server answers decline_release as an unknown '
          'message (BAD_TYPE) or as section 30 rule 4 says (WRONG_PHASE for '
          'the seat on turn, NOT_YOUR_TURN for the other), the same way '
          'every time, and plays on unchanged', () async {
        final Steer steer = Steer.faces(<int>[3]);
        await withFixture('C2 $ruleset decline_release', (Fixture fx) async {
          final Table t = await openTable(fx, players: 2, seeds: true);
          await startGame(t);
          final Map<int, List<Frame>> a =
              await t.step(0, 'decline_release', <String, Object?>{});
          final String onTurn = codeOf(fx, a[0]!.single, 'decline, own turn');
          fx.ok(
              onTurn == 'WRONG_PHASE' || onTurn == 'BAD_TYPE',
              'on turn, awaiting a roll: WRONG_PHASE (section 30 rule 4) or '
              'BAD_TYPE (unknown message), got $onTurn');
          fx.eq(a[2]!, <Frame>[], 'nobody else is told');
          final Map<int, List<Frame>> b =
              await t.step(2, 'decline_release', <String, Object?>{});
          final String offTurn = codeOf(fx, b[2]!.single, 'decline, off turn');
          fx.ok(
              offTurn == (onTurn == 'BAD_TYPE' ? 'BAD_TYPE' : 'NOT_YOUR_TURN'),
              'out of turn the same family: NOT_YOUR_TURN beside WRONG_PHASE, '
              'BAD_TYPE beside BAD_TYPE, got $offTurn after $onTurn');
          if (ruleset == v11) {
            force(t, drought: <int>[9, 0, 0, 0]);
            final Map<int, List<Frame>> roll =
                await t.step(0, 'roll', <String, Object?>{});
            fx.eq(dataOf(roll[0]!.single)['release'], true,
                'setup: a 2026-11 release is owed');
            final Map<int, List<Frame>> c =
                await t.step(0, 'decline_release', <String, Object?>{});
            fx.eq(codeOf(fx, c[0]!.single, 'decline with a release owed'),
                onTurn, 'there is no offer to decline under 2026-11');
            final Map<int, List<Frame>> take =
                await t.step(0, 'move', <String, Object?>{'token': 0});
            fx.ok(
                ofType(take[0]!, 'moved').length == 1,
                'the release owed is still takeable after the refusal',
                typesOf(take[0]!));
          } else {
            final Map<int, List<Frame>> roll =
                await t.step(0, 'roll', <String, Object?>{});
            fx.ok(ofType(roll[0]!, 'rolled').length == 1,
                'play goes on: the seat can still roll', typesOf(roll[0]!));
          }
        }, ruleset: ruleset, steer: steer);
      });
    }
  });
}
