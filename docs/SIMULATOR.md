# The headless four-client simulator

`packages/ludo_server/tool/simulator.dart` drives four independent WebSocket
clients through a complete Ludo game against a real, separately running
server process, over the wire protocol of `docs/PROTOCOL.md`, and exits `0`
only if every selected scenario reached the state the protocol says it must.

It speaks the wire directly. Nothing in `tool/sim/` imports
`test/support/wire_harness.dart` or anything else under `test/`, and nothing
in it decides legality, rolls a die, or advances a turn -- exactly the
restriction `docs/PROTOCOL.md` section 10 puts on a real client. It works
unchanged against a local `ws://127.0.0.1:<port>` and against a remote
`wss://` host, because it is the same client either way.

## Running it

```
export PATH=/path/to/dart-sdk/bin:$PATH
cd packages/ludo_server
PORT=8123 dart run bin/server.dart &
dart run tool/simulator.dart --target ws://127.0.0.1:8123 --scenario all
```

Flags:

| Flag | Default | Meaning |
|---|---|---|
| `--target` | required | Base WebSocket URL of a running server, `ws://` or `wss://`. Nothing is appended to it. |
| `--scenario` | `all` | `all`, `full-game`, `reconnect`, or `double-drop`. |
| `--timeout-seconds` | 180 | Bounds the whole run, not one frame. |
| `--players` | 4 | Seats to play with, 2 to 4. |

Exit code `0` means every selected scenario passed. Any other exit code means
at least one failed; nothing else signals the verdict. Output is one line per
scenario -- `PASS <name> <detail>` or `FAIL <name> <reason>` -- followed by
`simulator: N passed, M failed`.

## What each scenario proves

### `full-game`

Client A creates a room for `--players` seats and gets back the room code and
the chain commitment. Clients B, C and D join by that code, exactly the way a
friend with a shared link would. The host sets its own client seed (exercising
the `origin: "player"` path of `docs/PROTOCOL.md` section 11.2); the rest are
left for the server to assign at `start_game` (`origin: "server"`). A starts
the game, and all four play to a natural winner: every seat always sends a
legal move chosen from the `legal` list the server itself sent in that turn's
`rolled` frame, never one the simulator decided was legal on its own. Passes
only if the game ends in a `game_over` frame every one of the four sockets
received, naming the same winner, and every `rolled` frame observed along the
way satisfies the fairness assertion below.

### `reconnect`

The same game, but partway through -- after at least one roll has already
been played and verified -- one non-host client's socket is closed hard (the
raw connection, never a `leave_room` message). That client reconnects with a
fresh socket, sends `resume` with its stored `code` and `seat_token`
(`docs/PROTOCOL.md` section 8), receives the full room snapshot, and the
snapshot names the same seat as connected. The game then continues to a
winner with that seat back in play. Fails, rather than passing vacuously, if
the game reaches `game_over` before the reconnect trigger ever fires.

### `double-drop`

The same game, but two non-host clients drop at the same moment: both sockets
are closed before either reconnect begins, and both reconnects are then
raced concurrently, not run one after the other. Requires at least three
players (host plus two others to drop); with fewer it fails cleanly naming
the shortfall rather than dropping the same seat twice. Otherwise identical
in what it proves to `reconnect`.

## The fairness assertion

For every `rolled` frame observed on the driving socket in every scenario,
`tool/sim/fairness.dart` checks, using `package:fair_dice`'s own
`verifyReveal` and `drawDie` -- never a reimplementation of either:

1. the frame carries an integer `k` that is exactly one more than the
   previous verified `k` (`docs/PROTOCOL.md` section 12.1);
2. the frame carries a `reveal` that is 64 lowercase hex characters and
   satisfies `SHA-256(reveal) == ` the previous roll's `reveal`, or
   `chain_commit` for the first roll (`docs/FAIRNESS.md` section 2.1);
3. the frame's `value` equals `drawDie(reveal, game_id, client_seeds, k, 0)`
   computed from that same reveal, the `game_id` and the frozen
   `client_seeds` string the server itself published in `game_started`
   (`docs/FAIRNESS.md` section 2.3, `docs/PROTOCOL.md` section 11.2's "Ludo
   always uses die index `d = 0`").

A game that reaches a winner but whose rolls do not verify is a `FAIL`. The
reason line names the exact `k` that broke and which of the three checks
failed -- for example the reported `value`, the reveal that did not chain, or
the `k` that skipped -- so a failure is reproducible without re-running
anything with logging turned up.

`chain_commit` is also checked for stability: every `room` snapshot the
simulator receives for a room, including a `resume` reply after a reconnect,
must carry the same `chain_commit` the room started with. `docs/PROTOCOL.md`
section 11.2 forbids it changing for a given `chain_index`, and a change
would be a forged roll.

## Reading a failure line

Every `FAIL` line says what was expected, what happened, and (where the
protocol pins an order) the scenario or `k` needed to see it again:

- `expected a "<type>" frame (<step>) but got "<other type>": <payload>` --
  the server sent something other than what that step of the handshake or
  turn loop requires. If the unexpected frame was itself an `error`, its
  code and message are folded into the line instead of the raw payload.
- `k=<n>: ...` -- a fairness check failed at roll number `n`; see above for
  the three things that check.
- `<socket-label> expected another frame within <duration> and none
  arrived` -- a frame that step needed never showed up. The label names
  which socket (`host`, `guest-2`, `seat-1-reconnect-1`, ...) stalled.
- `the game reached game_over ... before the reconnect trigger ever fired`
  / `... before the double-drop trigger ever fired` -- the drop this
  scenario exists to test never happened, because the game finished first.
  This is a `FAIL`, not a vacuous pass: a reconnect scenario that never
  reconnected proved nothing.
- `did not finish within the overall --timeout-seconds N budget` -- the
  whole run, not one frame, exceeded its budget; raise `--timeout-seconds`
  or investigate why a game is taking this long.

## Notes for whoever runs this next

- Room creation is rate-limited to 5 per hour per IP
  (`docs/PROTOCOL.md` section 7), and every scenario creates exactly one
  room. A single `--scenario all` run uses 3 of that budget. Running the
  simulator repeatedly against the same server from the same machine within
  an hour will eventually hit `RATE_LIMITED` on `create_room` -- that is the
  server's rate limit doing its job, not a simulator defect.
- The simulator paces its own sends: a socket that is about to send twice
  within 50ms of its own previous send waits out the difference first. This
  exists because `docs/RULES.md` rule 10 grants an extra roll on a capture
  with no cap on how many can chain, and an automated player with no human
  reaction time between them can otherwise trip the connection's own
  `docs/PROTOCOL.md` section 7 limit of 30 messages per second -- a real
  client never approaches that ceiling. It only ever delays a socket that is
  genuinely sending back-to-back; an ordinary turn, with a real round trip
  to wait out in between, never notices it.
- A full four-player game with every seat always taking the first legal move
  the server offers is not a fast or a smart game -- it commonly runs to
  several hundred rolls. That is a property of the simulator's move
  selection, not of the protocol or the engine, and it is why the default
  `--timeout-seconds` is 180 rather than something tighter.
