// A Random that spells out a fixed room code on demand, for tests that need
// RoomRegistry to draw a specific code deterministically. This exists for
// exactly one purpose: proving the 24 hour code quarantine from
// docs/PROTOCOL.md section 3 ("a reaped room's code is not reissued for 24
// hours") without waiting on luck for a CSPRNG collision.
//
// On construction, and again after every call to rearm(), the next
// roomCodeLength calls to nextInt(32) return the alphabet indices of
// targetCode, one character at a time. Every other call -- nextInt with any
// other argument, or a call to nextInt(32) once the armed script for this
// round has been fully served -- is delegated to a real Random.secure() (or
// to whatever fallback the caller supplied).
//
// RoomRegistry is handed exactly one Random at construction and keeps it for
// the registry's whole lifetime, so a single-shot script cannot exercise a
// scenario that needs "force this code, let time pass, force it again".
// rearm() exists so one instance, and therefore one long-lived registry, can
// be driven through that scenario: force the code once to seed a room that
// gets reaped, rearm and force it again while quarantined to see it refused,
// then rearm and force it a third time after the quarantine window to see it
// accepted.
import 'dart:math';

import 'package:ludo_server/ludo_server.dart';

class ScriptedRandom implements Random {
  ScriptedRandom(this.targetCode, {Random? fallback})
      : _fallback = fallback ?? Random.secure(),
        _indices = _indicesFor(targetCode);

  final String targetCode;
  final Random _fallback;
  final List<int> _indices;
  int _served = 0;

  static List<int> _indicesFor(String code) {
    final List<int> indices = <int>[];
    for (final String char in code.split('')) {
      final int index = roomCodeAlphabet.indexOf(char);
      if (index < 0) {
        throw ArgumentError.value(
          code,
          'targetCode',
          'contains "$char", which is outside roomCodeAlphabet',
        );
      }
      indices.add(index);
    }
    return indices;
  }

  /// Resets the script so the next [roomCodeLength] calls to `nextInt(32)`
  /// spell [targetCode] again.
  void rearm() {
    _served = 0;
  }

  @override
  int nextInt(int max) {
    if (max == roomCodeAlphabet.length && _served < _indices.length) {
      final int value = _indices[_served];
      _served += 1;
      return value;
    }
    return _fallback.nextInt(max);
  }

  @override
  bool nextBool() => _fallback.nextBool();

  @override
  double nextDouble() => _fallback.nextDouble();
}
