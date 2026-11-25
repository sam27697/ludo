// docs/PROTOCOL.md section 34 item 5: the move a computer seat plays. The
// ranking is the app's hint (order 648, rules D2 to D7) computed on the server
// from the engine's board: least expected loss over all of the seat's pieces,
// then most gain, then the first candidate in wire order. It reads the board
// and the legal list and nothing else: no clock, no random source, no dice
// chain, no seed, no face that has not been rolled. Same input, same output.
//
// Where the ranking would name nothing (fewer than two different choices) the
// first candidate is played. D1's "same choice" is the same face and the same
// progress; it only decides whether there is a choice to rank.

/// The face and the token a computer seat plays.
class ComputerChoice {
  const ComputerChoice({required this.face, required this.token});

  final int face;
  final int token;

  @override
  bool operator ==(Object other) =>
      other is ComputerChoice && other.face == face && other.token == token;

  @override
  int get hashCode => Object.hash(face, token);

  @override
  String toString() => 'ComputerChoice(face: $face, token: $token)';
}

/// Absolute squares a token can never be captured on (RULES.md 1.2).
const Set<int> _safeSquares = <int>{0, 8, 13, 21, 26, 34, 39, 47};

/// The move [seat] plays on the board [tokens] (seat to the progress of each
/// of its four tokens, -1 yard, 0..51 track, 52..56 home column, 57 home)
/// with [legal] the legal tokens by face in wire order. Null only when
/// [legal] holds no candidate at all.
ComputerChoice? chooseComputerMove({
  required int seat,
  required Map<int, List<int>> tokens,
  required List<(int face, List<int> tokens)> legal,
}) {
  final List<_Candidate> candidates = <_Candidate>[];
  int order = 0;
  for (final (int face, List<int> tokenList) in legal) {
    // Wire order is the face first, then the lowest token index.
    final List<int> indexes = List<int>.of(tokenList)..sort();
    for (final int token in indexes) {
      final int? progress = _progressAt(tokens, seat, token);
      if (progress == null) {
        continue;
      }
      candidates.add(
        _Candidate(face: face, token: token, progress: progress, order: order),
      );
      order += 1;
    }
  }
  if (candidates.isEmpty) {
    return null;
  }
  final Set<(int, int)> choices = <(int, int)>{
    for (final _Candidate candidate in candidates)
      (candidate.face, candidate.progress),
  };
  if (choices.length < 2) {
    final _Candidate only = candidates.first;
    return ComputerChoice(face: only.face, token: only.token);
  }
  _Scored? best;
  for (final _Candidate candidate in candidates) {
    final _Scored scored = _score(seat, tokens, candidate);
    if (best == null || _beats(scored, best)) {
      best = scored;
    }
  }
  return ComputerChoice(
    face: best!.candidate.face,
    token: best.candidate.token,
  );
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

  /// D5, in 216ths of a progress step.
  final int loss;

  /// D6.
  final int gain;
}

int? _progressAt(Map<int, List<int>> tokens, int seat, int token) {
  final List<int>? mine = tokens[seat];
  if (mine == null || token < 0 || token >= mine.length) {
    return null;
  }
  return mine[token];
}

/// RULES.md 1.1, as D2 states it.
int _absolute(int seat, int progress) => (13 * seat + progress) % 52;

/// `0` when [progress] is the yard (D2).
int _dest(int progress, int face) => progress == -1 ? 0 : progress + face;

/// D2, D5 and D6 for one candidate.
_Scored _score(int seat, Map<int, List<int>> tokens, _Candidate candidate) {
  final int dest = _dest(candidate.progress, candidate.face);
  final _Victim? victim = _victimOn(seat, dest, tokens);
  final Map<int, List<int>> after = _boardAfter(
    tokens: tokens,
    seat: seat,
    token: candidate.token,
    dest: dest,
    victim: victim,
  );
  final int gain = (dest - candidate.progress) +
      (victim == null ? 0 : victim.progress + 1) +
      (dest == 57 ? 6 : 0) +
      (candidate.progress == -1 ? 6 : 0);
  return _Scored(
    candidate: candidate,
    loss: _expectedLoss(seat, after),
    gain: gain,
  );
}

/// D7: lowest loss, then highest gain, then the earlier candidate.
bool _beats(_Scored a, _Scored b) {
  if (a.loss != b.loss) {
    return a.loss < b.loss;
  }
  if (a.gain != b.gain) {
    return a.gain > b.gain;
  }
  return a.candidate.order < b.candidate.order;
}

/// The one opponent token a landing on [dest] would send home, or null when
/// the landing is no capture (D2): a safe square, or a square holding two or
/// more tokens of other seats, captures nothing.
_Victim? _victimOn(int seat, int dest, Map<int, List<int>> tokens) {
  if (dest < 0 || dest > 51) {
    return null;
  }
  final int square = _absolute(seat, dest);
  if (_safeSquares.contains(square)) {
    return null;
  }
  _Victim? found;
  for (final MapEntry<int, List<int>> entry in tokens.entries) {
    if (entry.key == seat) {
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
  required int seat,
  required int token,
  required int dest,
  required _Victim? victim,
}) {
  final Map<int, List<int>> next = <int, List<int>>{
    for (final MapEntry<int, List<int>> entry in tokens.entries)
      entry.key: List<int>.of(entry.value),
  };
  final List<int>? mine = next[seat];
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

/// Sum over the seat's unsheltered tokens of `hit216 * (progress + 1)` (D3,
/// D5). Exact integers, no doubles.
int _expectedLoss(int seat, Map<int, List<int>> tokens) {
  final List<int> mine = tokens[seat] ?? const <int>[];
  final List<int> opponents = <int>[
    for (final int other in tokens.keys)
      if (other != seat) other,
  ];
  int loss = 0;
  for (int index = 0; index < mine.length; index++) {
    final int progress = mine[index];
    if (_sheltered(seat: seat, token: index, progress: progress, mine: mine)) {
      continue;
    }
    final int square = _absolute(seat, progress);
    int miss = 1;
    for (final int other in opponents) {
      miss *= 6 - _hitFaces(other, tokens[other]!, square).length;
    }
    for (int pad = opponents.length; pad < 3; pad++) {
      miss *= 6;
    }
    loss += (216 - miss) * (progress + 1);
  }
  return loss;
}

/// D4: the faces on which a token of [seat] reaches [square] with its next
/// roll. Blocks in between are ignored; yard tokens and tokens past the main
/// track never threaten.
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

/// D3: off the main track, on a safe square, or paired with another of the
/// seat's tokens on the same progress.
bool _sheltered({
  required int seat,
  required int token,
  required int progress,
  required List<int> mine,
}) {
  if (progress < 0 || progress > 51) {
    return true;
  }
  if (_safeSquares.contains(_absolute(seat, progress))) {
    return true;
  }
  for (int index = 0; index < mine.length; index++) {
    if (index != token && mine[index] == progress) {
      return true;
    }
  }
  return false;
}
