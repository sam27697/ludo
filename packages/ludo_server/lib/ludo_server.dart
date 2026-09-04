/// The authoritative Ludo game server: the in-memory room registry
/// (`docs/PROTOCOL.md` sections 2, 3 and 12), and the wire layer on top of it
/// -- envelope parsing, the section 7 validation ladder, rate limits, the
/// `shelf` + `shelf_web_socket` socket handling and the reap/prune
/// housekeeping timer, and the turn timer that plays for a seat whose segment
/// runs out (`docs/RULES.md` section 3.3).
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
        SetSeedResult,
        SetSeedOk,
        SetSeedFailure,
        SetPlayersResult,
        SetPlayersOk,
        SetPlayersFailure,
        LeaveResult,
        LeaveOk,
        LeaveFailure,
        RollResult,
        RollOk,
        RollFailure,
        MoveResult,
        MoveOk,
        MoveFailure,
        ExpiredTurn,
        RoomRegistry;
export 'src/rate_limit.dart' show RateLimiter, MessageRateOutcome;
export 'src/envelope.dart'
    show
        maxFrameBytes,
        isWellFormedMessageId,
        wireErrorCode,
        knownMessageTypes,
        parseEnvelope,
        encodeEnvelope,
        generateMessageId;
export 'src/connection.dart' show Connection, RoomHub;
// The turn timer's frames: the registry decides the turn, this builds
// what section 12 says goes on the wire for it, and the wire layer only
// broadcasts. Exported so both halves are testable without a socket.
export 'src/snapshot.dart' show OutFrame, buildExpiryFrames;
export 'src/privacy_page.dart' show buildPrivacyPageHtml, privacyLastUpdated;
export 'src/wire_server.dart'
    show WireServer, housekeepingInterval, turnExpiryInterval;

// GameState is ludo_engine's, not this package's, but Room.game exposes it
// and a caller of this package should not have to depend on ludo_engine
// directly just to read that field.
export 'package:ludo_engine/ludo_engine.dart' show GameState;
