// docs/PROTOCOL.md section 34 items 1, 4 and 5: the six characters a computer
// seat can be, the pace it acts at, and the decision it makes on a turn. This
// file draws from a `Random` it is handed and never owns one: the registry
// makes one per room from its injected factory, which is never the source the
// dice come from.

import 'dart:math';

import 'package:ludo_engine/ludo_engine.dart' as engine;

import 'computer_choice.dart';
import 'room.dart';

/// Item 1: the characters by `bot` number; `bot` 1 is index 0.
const List<String> computerCharacters = <String>[
  'Zuzu',
  'Nono',
  'Kiko',
  'Bobo',
  'Tutu',
  'Mimi',
];

/// Item 4: a computer seat's pace, whole milliseconds, both ends included.
const int computerPaceMinMs = 800;
const int computerPaceMaxMs = 1600;

/// Item 3: `fill_computer` is refused until this long after the room was
/// created, or last returned to LOBBY by a rematch, on the server clock.
const int fillComputerWaitMs = 60000;

/// Item 3: the milliseconds left until `fill_computer` is allowed in [room]
/// at [now], 0 once it is. Counted from the creation of the room or the last
/// return to LOBBY by a rematch, which is where `Room.lifetimeStartedAt`
/// stands.
int fillMsLeft(Room room, DateTime now) {
  final int left = fillComputerWaitMs -
      now.difference(room.lifetimeStartedAt).inMilliseconds;
  return left > 0 ? left : 0;
}

/// The English name of character [bot] (1 to 6).
String computerName(int bot) => computerCharacters[bot - 1];

/// [count] distinct characters, 1 to 6, none of them in [taken], drawn
/// without replacement from [random]. Throws when fewer remain than asked
/// for, which the two- and four-seat rooms never reach.
List<int> drawComputerCharacters(
  Random random,
  int count, {
  Set<int> taken = const <int>{},
}) {
  final List<int> remaining = <int>[
    for (int bot = 1; bot <= computerCharacters.length; bot++)
      if (!taken.contains(bot)) bot,
  ];
  if (count > remaining.length) {
    throw ArgumentError.value(count, 'count', 'more than the characters left');
  }
  final List<int> drawn = <int>[];
  for (int i = 0; i < count; i++) {
    drawn.add(remaining.removeAt(random.nextInt(remaining.length)));
  }
  return drawn;
}

/// A pace, uniform over [computerPaceMinMs] to [computerPaceMaxMs].
int drawComputerPaceMs(Random random) =>
    computerPaceMinMs +
    random.nextInt(computerPaceMaxMs - computerPaceMinMs + 1);

/// What a computer seat does with the turn it holds.
sealed class ComputerAction {
  const ComputerAction();
}

/// A roll is owed.
class ComputerRoll extends ComputerAction {
  const ComputerRoll();
}

/// A move is owed: [token], and the face to spend, null for a yard release.
class ComputerMove extends ComputerAction {
  const ComputerMove({required this.token, required this.face});

  final int token;
  final int? face;
}

/// The one action the seat on turn takes in [game], or null when the game is
/// over or no action is owed. A roll when a roll is owed; a release when one
/// is owed (the lowest releasable token); otherwise the move item 5 ranks.
ComputerAction? decideComputerAction(engine.GameState game) {
  switch (game.phase) {
    case engine.GamePhase.finished:
      return null;
    case engine.GamePhase.awaitRoll:
      return const ComputerRoll();
    case engine.GamePhase.awaitMove:
      break;
  }
  if (game.releaseOwed) {
    final List<int> releasable = List<int>.of(engine.legalTokens(game))..sort();
    if (releasable.isEmpty) {
      return null;
    }
    return ComputerMove(token: releasable.first, face: null);
  }
  final List<(int face, List<int> tokens)> legal = <(int, List<int>)>[
    for (final MapEntry<int, List<int>> entry
        in engine.legalByFace(game).entries)
      (entry.key, entry.value),
  ];
  final ComputerChoice? choice = chooseComputerMove(
    seat: game.currentSeat,
    tokens: <int, List<int>>{
      for (final int s in game.config.seats) s: game.tokens[s],
    },
    legal: legal,
  );
  if (choice == null) {
    return null;
  }
  return ComputerMove(token: choice.token, face: choice.face);
}
