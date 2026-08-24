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
}
