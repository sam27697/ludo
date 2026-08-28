// Plain enums, docs/ENGINE_API.md section 2 and section 4.

enum GamePhase { awaitRoll, awaitMove, finished }

enum TurnEndReason { noLegalMove, threeSixes }

enum EngineError {
  notYourTurn,
  wrongPhase,
  illegalMove,
  gameFinished,
  seatNotInPlay,
  noSuchToken,
  // badFace is appended at the end, after noSuchToken, on purpose: appending
  // keeps every existing .name and .index stable, which the golden corpus's
  // optional error field depends on. Do not reorder this enum.
  badFace,
}
