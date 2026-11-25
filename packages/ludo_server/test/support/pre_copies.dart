// docs/PROTOCOL.md section 35 item 1 for suites that compare the copies of
// one broadcast across sockets: the copy of an `await_roll` `turn` frame that
// goes to the socket of the seat on turn carries `pre`, and no other copy
// does. These helpers check exactly that, then hand back the copy without
// the one key so the rest of the frame is still compared byte for byte.

import 'package:test/test.dart';

/// Keys a `pre` may hold: the `rolled` `d` without `seq`, `reveal`,
/// `deadline_ms` and `by` (section 35 item 1, item 7 for `offer`).
const Set<String> preKeys = <String>{
  'seat',
  'value',
  'legal',
  'k',
  'queue',
  'legal_by_face',
  'release',
  'offer',
};

/// [d] without `pre`.
Map<String, Object?> withoutPre(Map<String, Object?> d) =>
    Map<String, Object?>.of(d)..remove('pre');

/// The `d` of [frame] without `pre` when it is a `turn`; otherwise `d` as is.
Object? dWithoutPre(Map<String, Object?> frame) {
  final Object? d = frame['d'];
  if (frame['t'] != 'turn' || d is! Map<String, Object?>) {
    return d;
  }
  return withoutPre(d);
}

/// Checks the shape of [pre] for the seat on turn [seat].
void expectPreShape(Object? pre, int seat, String where) {
  expect(pre, isA<Map<String, Object?>>(),
      reason: '$where: section 35 item 1: the seat on turn\'s own copy of an '
          'await_roll turn carries "pre" as an object; got $pre');
  final Map<String, Object?> p = pre! as Map<String, Object?>;
  expect(p.keys.toSet().difference(preKeys), isEmpty,
      reason: '$where: pre holds only the rolled keys less seq, reveal, '
          'deadline_ms and by; got $p');
  expect(p['seat'], seat, reason: '$where: pre.seat is the seat on turn; $p');
  expect(p['value'], isA<int>(), reason: '$where: pre.value; $p');
  expect((p['value']! as int) >= 1 && (p['value']! as int) <= 6, isTrue,
      reason: '$where: pre.value is a face 1..6; $p');
  expect(p['legal'], isA<List<Object?>>(), reason: '$where: pre.legal; $p');
  expect(p['queue'], isA<List<Object?>>(), reason: '$where: pre.queue; $p');
  expect(p['k'], isA<int>(), reason: '$where: pre.k; $p');
  expect((p['k']! as int) >= 1, isTrue, reason: '$where: pre.k >= 1; $p');
}

/// Section 35 item 1 over the copies of one frame. [copies] pairs each
/// socket's seat with the `d` it received. When the frame is a `turn` in
/// `await_roll`, the copy of the seat on turn must carry a well-formed `pre`
/// and every other copy none; on any other frame no copy carries `pre`.
/// [seatKnown] false: the sockets' seats are not known to the caller, every
/// one of them is seated and the seat on turn is among them (a two-seat
/// room with both sockets read), so exactly one copy must carry `pre`.
void expectPreOnRollerOnly(
  String type,
  List<(int?, Map<String, Object?>)> copies,
  String where, {
  bool seatKnown = true,
}) {
  if (copies.isEmpty) {
    return;
  }
  final Map<String, Object?> d0 = copies.first.$2;
  final bool rollTurn = type == 'turn' && d0['phase'] == 'await_roll';
  if (!rollTurn) {
    for (final (int? seat, Map<String, Object?> d) in copies) {
      expect(d.containsKey('pre'), isFalse,
          reason: '$where: section 35 item 1: "pre" rides only an '
              'await_roll turn; the $type copy of seat $seat carries it: $d');
    }
    return;
  }
  final int onTurn = d0['seat']! as int;
  if (seatKnown) {
    for (final (int? seat, Map<String, Object?> d) in copies) {
      if (seat == onTurn) {
        expectPreShape(d['pre'], onTurn, '$where (seat $seat, own copy)');
      } else {
        expect(d.containsKey('pre'), isFalse,
            reason: '$where: section 35 item 1: seat $seat\'s copy of the '
                'turn for seat $onTurn carries no "pre"; got $d');
      }
    }
    return;
  }
  final List<Map<String, Object?>> withPre = <Map<String, Object?>>[
    for (final (int? _, Map<String, Object?> d) in copies)
      if (d.containsKey('pre')) d,
  ];
  expect(withPre.length, 1,
      reason: '$where: section 35 item 1: of the ${copies.length} copies of '
          'the await_roll turn for seat $onTurn exactly one (the seat on '
          'turn\'s own) carries "pre"; got ${[
        for (final (int? _, Map<String, Object?> d) in copies) d
      ]}');
  expectPreShape(withPre.single['pre'], onTurn, where);
}
