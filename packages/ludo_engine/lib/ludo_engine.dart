/// Pure Ludo rules engine. No I/O, no framework, no networking, no clock.
///
/// This is the single public entry point. Every type and function below is
/// the whole public surface, frozen by `docs/ENGINE_API.md`. Everything
/// under `lib/src/` is an implementation detail.
library;

export 'src/apply_result.dart' show ApplyResult, Applied, Rejected;
export 'src/enums.dart' show GamePhase, TurnEndReason, EngineError;
export 'src/events.dart'
    show
        GameEvent,
        Rolled,
        Moved,
        Captured,
        TokenHome,
        ExtraRoll,
        TurnEnded,
        TurnBegan,
        GameWon;
export 'src/game_config.dart' show GameConfig;
export 'src/game_state.dart' show GameState;
export 'src/intentions.dart' show Intention, RollIntention, MoveIntention;
export 'src/rules_config.dart' show RulesConfig;
export 'src/hash.dart' show stateHash;
export 'src/engine_core.dart' show newGame, apply, legalTokens, isTerminal;
