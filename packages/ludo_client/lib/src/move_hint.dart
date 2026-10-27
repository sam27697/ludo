// One best-move hint per game (C-471 D1, D2). The legal list is the
// server's; nothing here reads a die that is not already in that list,
// a seed, or a clock. Same input, same output.

import 'board_geometry.dart';

/// The token and the face [recommendMove] names (C-471 D2).
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

  final List<_Scored> scored = <_Scored>[
    for (final _Candidate candidate in candidates)
      _score(mySeat, tokens, candidate),
  ];
  _Scored best = scored.first;
  for (final _Scored other in scored.skip(1)) {
    if (_beats(other, best)) {
      best = other;
    }
  }
  return MoveHint(token: best.candidate.token, face: best.candidate.face);
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
    required this.tier,
    required this.capturedProgress,
    required this.threatenedAfter,
  });

  final _Candidate candidate;
  final int tier;
  final int capturedProgress;
  final bool threatenedAfter;
}

int? _progressAt(Map<int, List<int>> tokens, int seat, int token) {
  final List<int>? mine = tokens[seat];
  if (mine == null || token < 0 || token >= mine.length) {
    return null;
  }
  return mine[token];
}

/// RULES.md 1.1, as C-471 D2 states it.
int _absolute(int seat, int progress) => (13 * seat + progress) % 52;

/// `0` when [progress] is the yard. The server only offers that on a
/// legal 6; this function does not recheck the face (C-471 D2).
int _dest(int progress, int face) => progress == -1 ? 0 : progress + face;

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
  final bool threatenedNow = _threatened(
    mySeat: mySeat,
    token: candidate.token,
    progress: candidate.progress,
    tokens: tokens,
  );
  final bool threatenedAfter = _threatened(
    mySeat: mySeat,
    token: candidate.token,
    progress: dest,
    tokens: after,
  );

  // First matching tier wins (C-471 D2). Home column and home are never
  // threatened, so a move that lands there is not threatened after.
  final int tier;
  if (victim != null) {
    tier = 1;
  } else if (dest == 57) {
    tier = 2;
  } else if (threatenedNow && !threatenedAfter) {
    tier = 3;
  } else if (candidate.progress == -1) {
    tier = 4;
  } else if (!threatenedAfter) {
    tier = 5;
  } else {
    tier = 6;
  }
  return _Scored(
    candidate: candidate,
    tier: tier,
    capturedProgress: victim?.progress ?? 0,
    threatenedAfter: threatenedAfter,
  );
}

/// True when [a] is the one to keep over [b]. Tier first, then that
/// tier's tie-break, then the earlier D1 candidate (C-471 D2).
bool _beats(_Scored a, _Scored b) {
  if (a.tier != b.tier) {
    return a.tier < b.tier;
  }
  switch (a.tier) {
    case 1:
      if (a.capturedProgress != b.capturedProgress) {
        return a.capturedProgress > b.capturedProgress;
      }
      if (a.threatenedAfter != b.threatenedAfter) {
        return !a.threatenedAfter;
      }
      return a.candidate.order < b.candidate.order;
    case 3:
    case 5:
    case 6:
      if (a.candidate.progress != b.candidate.progress) {
        return a.candidate.progress > b.candidate.progress;
      }
      return a.candidate.order < b.candidate.order;
    default:
      return a.candidate.order < b.candidate.order;
  }
}

/// The one opponent token a landing on [dest] would send home, or null
/// when the landing is not a capture (C-471 D2). Safe squares and a
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

/// Main-track [progress] only. Yard tokens are no threat and are never
/// threatened; home column and home are never threatened (C-471 D2).
bool _threatened({
  required int mySeat,
  required int token,
  required int progress,
  required Map<int, List<int>> tokens,
}) {
  if (progress < 0 || progress > 51) {
    return false;
  }
  if (_sheltered(
    mySeat: mySeat,
    token: token,
    progress: progress,
    tokens: tokens,
  )) {
    return false;
  }
  final int square = _absolute(mySeat, progress);
  for (final MapEntry<int, List<int>> entry in tokens.entries) {
    if (entry.key == mySeat) {
      continue;
    }
    for (final int q in entry.value) {
      if (q < 0 || q > 51) {
        continue;
      }
      final int behind = _absolute(entry.key, q);
      final int distance = (square - behind) % 52;
      if (distance >= 1 && distance <= 6 && q + distance <= 51) {
        return true;
      }
    }
  }
  return false;
}

/// Safe square, or another of my own tokens already on this progress.
/// A pair is never captured (C-471 D2, RULES.md 21 and 28a).
bool _sheltered({
  required int mySeat,
  required int token,
  required int progress,
  required Map<int, List<int>> tokens,
}) {
  if (safeTrackSquares.contains(_absolute(mySeat, progress))) {
    return true;
  }
  final List<int>? mine = tokens[mySeat];
  if (mine == null) {
    return false;
  }
  for (int index = 0; index < mine.length; index++) {
    if (index == token) {
      continue;
    }
    if (mine[index] == progress) {
      return true;
    }
  }
  return false;
}
