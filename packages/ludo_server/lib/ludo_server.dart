/// The in-memory room registry: codes, seat tokens, seats and the room
/// lifecycle of `docs/PROTOCOL.md` sections 2 and 3. No WebSocket, no HTTP,
/// no `shelf`, no timer driven by the wall clock -- that lands with the
/// socket layer in a later order.
library;

export 'src/clock.dart' show Clock, SystemClock, FakeClock;
export 'src/room_code.dart'
    show
        roomCodeAlphabet,
        roomCodeLength,
        generateRoomCode,
        isWellFormedRoomCode;
export 'src/seat_token.dart' show generateSeatToken, isWellFormedSeatToken;
export 'src/room.dart' show RulesConfig, RoomState, Seat, Room;
export 'src/registry.dart'
    show
        ProtocolError,
        CreateResult,
        CreateOk,
        CreateFailure,
        JoinResult,
        JoinOk,
        JoinFailure,
        ResumeResult,
        ResumeOk,
        ResumeFailure,
        StartResult,
        StartOk,
        StartFailure,
        SetPlayersResult,
        SetPlayersOk,
        SetPlayersFailure,
        LeaveResult,
        LeaveOk,
        LeaveFailure,
        RoomRegistry;

// GameState is ludo_engine's, not this package's, but Room.game exposes it
// and a caller of this package should not have to depend on ludo_engine
// directly just to read that field.
export 'package:ludo_engine/ludo_engine.dart' show GameState;
