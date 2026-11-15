// One best-move hint per game (C-471 D1, C-648 D2..D7). The hint picks the
// move that leaves the least expected loss across all of my pieces, not
// only the one that moves; among equal loss it takes the most gain. The
// legal list is the server's; nothing here reads a die that is not
// already in that list, a seed, or a clock. Same input, same output.

import 'board_geometry.dart';

/// The token and the face [recommendMove] names (C-648 D7).
class MoveHint {
  const MoveHint({required this.token, required this.face});

  final int token;
  final int face;

  @override
  bool operator ==(Object other) {
    return other is MoveHint && other.token == token && other.face == face;
  }

  @override
  int get hashCode => Object.hash(token, face);

  @override
  String toString() => 'MoveHint(token: $token, face: $face)';
}

/// Null when fewer than two different choices exist (C-471 D1).
MoveHint? recommendMove({
  required int mySeat,
  required Map<int, List<int>> tokens,
  required List<(int face, List<int> tokens)> legal,
}) {
  final List<_Candidate> candidates = <_Candidate>[];
  int order = 0;
  for (final (int face, List<int> tokenList) in legal) {
    // D1 order is face in wire order, then lowest token index. Copy
    // before sorting so the caller's list stays as the wire sent it.
    final List<int> indexes = List<int>.of(tokenList)..sort();
    for (final int token in indexes) {
      final int? progress = _progressAt(tokens, mySeat, token);
      if (progress == null) {
        continue;
      }
      candidates.add(
        _Candidate(face: face, token: token, progress: progress, order: order),
      );
      order += 1;
    }
  }

  // Two candidates are the same choice when the face matches and the
  // tokens stand on the same progress (C-471 D1).
  final Set<(int, int)> choices = <(int, int)>{
    for (final _Candidate candidate in candidates)
      (candidate.face, candidate.progress),
  };
  if (choices.length < 2) {
    return null;
  }

  _Scored? best;
  for (final _Candidate candidate in candidates) {
    final _Scored scored = _score(mySeat, tokens, candidate);
    if (best == null || _beats(scored, best)) {
      best = scored;
    }
  }
  return MoveHint(token: best!.candidate.token, face: best.candidate.face);
}

class _Candidate {
  const _Candidate({
    required this.face,
    required this.token,
    required this.progress,
    required this.order,
  });

  final int face;
  final int token;
  final int progress;
  final int order;
}

class _Victim {
  const _Victim({
    required this.seat,
    required this.token,
    required this.progress,
  });

  final int seat;
  final int token;
  final int progress;
}

class _Scored {
  const _Scored({
    required this.candidate,
    required this.loss,
    required this.gain,
  });

  final _Candidate candidate;

  /// C-648 D5, in 216ths of a progress step.
  final int loss;

  /// C-648 D6.
  final int gain;
}

int? _progressAt(Map<int, List<int>> tokens, int seat, int token) {
  final List<int>? mine = tokens[seat];
  if (mine == null || token < 0 || token >= mine.length) {
    return null;
  }
  return mine[token];
}

/// RULES.md 1.1, as C-648 D2 states it.
int _absolute(int seat, int progress) => (13 * seat + progress) % 52;

/// `0` when [progress] is the yard. The server only offers that on a
/// legal 6; this function does not recheck the face (C-648 D2).
int _dest(int progress, int face) => progress == -1 ? 0 : progress + face;

/// C-648 D2, D5, D6 for one candidate.
_Scored _score(int mySeat, Map<int, List<int>> tokens, _Candidate candidate) {
  final int dest = _dest(candidate.progress, candidate.face);
  final _Victim? victim = _victimOn(mySeat, dest, tokens);
  final Map<int, List<int>> after = _boardAfter(
    tokens: tokens,
    mySeat: mySeat,
    token: candidate.token,
    dest: dest,
    victim: victim,
  );
  final int gain =
      (dest - candidate.progress) +
      (victim == null ? 0 : victim.progress + 1) +
      (dest == 57 ? 6 : 0) +
      (candidate.progress == -1 ? 6 : 0);
  return _Scored(
    candidate: candidate,
    loss: _expectedLoss(mySeat, after),
    gain: gain,
  );
}

/// True when [a] is the one to keep over [b]: lowest loss, then highest
/// gain, then the earlier D1 candidate (C-648 D7).
bool _beats(_Scored a, _Scored b) {
  if (a.loss != b.loss) {
    return a.loss < b.loss;
  }
  if (a.gain != b.gain) {
    return a.gain > b.gain;
  }
  return a.candidate.order < b.candidate.order;
}

/// The one opponent token a landing on [dest] would send home, or null
/// when the landing is not a capture (C-648 D2). Safe squares and a
/// square holding two or more other-seat tokens capture nothing.
_Victim? _victimOn(int mySeat, int dest, Map<int, List<int>> tokens) {
  if (dest < 0 || dest > 51) {
    return null;
  }
  final int square = _absolute(mySeat, dest);
  if (safeTrackSquares.contains(square)) {
    return null;
  }
  _Victim? found;
  for (final MapEntry<int, List<int>> entry in tokens.entries) {
    if (entry.key == mySeat) {
      continue;
    }
    final List<int> progresses = entry.value;
    for (int index = 0; index < progresses.length; index++) {
      final int progress = progresses[index];
      if (progress < 0 || progress > 51) {
        continue;
      }
      if (_absolute(entry.key, progress) != square) {
        continue;
      }
      if (found != null) {
        return null;
      }
      found = _Victim(seat: entry.key, token: index, progress: progress);
    }
  }
  return found;
}

Map<int, List<int>> _boardAfter({
  required Map<int, List<int>> tokens,
  required int mySeat,
  required int token,
  required int dest,
  required _Victim? victim,
}) {
  final Map<int, List<int>> next = <int, List<int>>{
    for (final MapEntry<int, List<int>> entry in tokens.entries)
      entry.key: List<int>.of(entry.value),
  };
  final List<int>? mine = next[mySeat];
  if (mine != null && token >= 0 && token < mine.length) {
    mine[token] = dest;
  }
  if (victim != null) {
    final List<int>? theirs = next[victim.seat];
    if (theirs != null && victim.token >= 0 && victim.token < theirs.length) {
      theirs[victim.token] = -1;
    }
  }
  return next;
}

/// Sum over my unsheltered tokens of `hit216 * (progress + 1)` on [tokens]
/// (C-648 D3, D5). Exact integers; no doubles.
int _expectedLoss(int mySeat, Map<int, List<int>> tokens) {
  final List<int> mine = tokens[mySeat] ?? const <int>[];
  final List<int> opponents = <int>[
    for (final int seat in tokens.keys)
      if (seat != mySeat) seat,
  ];
  int loss = 0;
  for (int index = 0; index < mine.length; index++) {
    final int progress = mine[index];
    if (_sheltered(
      mySeat: mySeat,
      token: index,
      progress: progress,
      mine: mine,
    )) {
      continue;
    }
    final int square = _absolute(mySeat, progress);
    int miss = 1;
    for (final int seat in opponents) {
      miss *= 6 - _hitFaces(seat, tokens[seat]!, square).length;
    }
    for (int pad = opponents.length; pad < 3; pad++) {
      miss *= 6;
    }
    loss += (216 - miss) * (progress + 1);
  }
  return loss;
}

/// F_o of C-648 D4: the faces on which a token of [seat] reaches [square]
/// with its next roll. Blocks in between are ignored; yard tokens and
/// tokens past the main track never threaten.
Set<int> _hitFaces(int seat, List<int> progresses, int square) {
  final Set<int> faces = <int>{};
  for (final int q in progresses) {
    if (q < 0 || q > 51) {
      continue;
    }
    final int distance = (square - _absolute(seat, q)) % 52;
    if (distance >= 1 && distance <= 6 && q + distance <= 51) {
      faces.add(distance);
    }
  }
  return faces;
}

/// C-648 D3: off the main track, on a safe square, or paired with another
/// of my tokens on the same progress (RULES.md 21 and 28a).
bool _sheltered({
  required int mySeat,
  required int token,
  required int progress,
  required List<int> mine,
}) {
  if (progress < 0 || progress > 51) {
    return true;
  }
  if (safeTrackSquares.contains(_absolute(mySeat, progress))) {
    return true;
  }
  for (int index = 0; index < mine.length; index++) {
    if (index != token && mine[index] == progress) {
      return true;
    }
  }
  return false;
}
