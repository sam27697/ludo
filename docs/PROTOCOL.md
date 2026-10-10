# Protocol

Frozen 2026-08-18. **Amended 2026-08-28 for verifiable dice**; the amendment is
section 11, and every table below already carries it. This is master-written and
it is not a work order's to change. An implementation that cannot satisfy this
file reports that; it does not adjust the file.

Transport is a single WebSocket per client over TLS. Messages are JSON objects,
UTF-8, one message per frame. The stack that carries this is decided in
`docs/STACK.md` and does not change anything below.

## 1. Shape

Every message, both directions:

```json
{ "v": 1, "t": "<type>", "id": "<string>", "d": { } }
```

| Field | Meaning |
|---|---|
| `v` | protocol version, integer, currently `1`. A client sending an unknown `v` is closed with `PROTOCOL_VERSION`. |
| `t` | message type, from the tables below. Unknown type is `BAD_TYPE`. |
| `id` | client-generated message id for client to server, server-generated for server to client. Opaque, 8 to 64 characters, `[A-Za-z0-9_-]`. |
| `d` | payload object. Always present, possibly empty. |

A server reply that answers a specific client message carries `re`, the `id` it
answers. Unsolicited server pushes have no `re`.

Maximum frame size is 8192 bytes. A larger frame is not parsed: the connection
is closed with `TOO_LARGE`. This is checked before JSON parsing, on the byte
count, because the point is to not hand attacker-sized input to a parser.

## 2. Identity and the two secrets

There are exactly two secrets in this protocol and they are different things.

- **Room code.** Short, human-readable, dictatable over a phone call. It is the
  capability to *join* a room. 6 characters from the alphabet
  `ABCDEFGHJKLMNPQRSTUVWXYZ23456789` -- 32 symbols. `0`, `O`, `1` and `I` are
  all excluded. `L` is kept deliberately: with `1` gone there is nothing left
  for it to be confused with, and dropping it would leave 31 symbols.
  Generated from a CSPRNG, never sequential, never derived from a counter or a
  timestamp. That is 32^6, about 1.07e9 codes; combined with the rate limits in
  section 7 it is not enumerable.
- **Seat token.** Long, opaque, never shown to a human. It is the capability to
  *be* a particular player in a particular room. 32 bytes from a CSPRNG,
  base64url. Issued once when a seat is taken, and it is the only thing that
  reclaims that seat after a disconnect. A client stores it and does not log it.
  The server never accepts a seat claim on any other basis, and specifically not
  on an IP address, a device id or a display name.

Losing the seat token means losing the seat. That is the intended behaviour: a
seat is not reassignable by anything a third party can observe.

## 3. Room lifecycle

    LOBBY ----start----> PLAYING ----winner----> FINISHED ----> (reaped)
      |                     |                                      ^
      |                     +---------- all seats gone ------------+
      +----- empty for 10 min, or 60 min total ---------------------+

- **LOBBY.** Created by the host. Accepts joins up to the configured player
  count. Only the host may start it, and only when **every configured seat is
  filled**. The host may change the player count while in LOBBY, down to no
  fewer than the seats currently occupied; doing so re-seats everyone onto the
  canonical seat set for the new count.
- **PLAYING.** No new seats. A disconnected seat stays in the game and its turns
  are played by the timer under rule 15 of `docs/RULES.md`.
- **FINISHED.** Terminal for that game. A `rematch` (section 16) takes the room
  back to LOBBY with a new chain; without one, the final state is served to anyone reconnecting, for
  10 minutes, then the room is reaped.
- A room in any state is reaped 60 minutes after creation regardless. A LOBBY
  with no connected clients is reaped after 10 minutes.
- A reaped room's code is not reissued for 24 hours.

## 4. Client to server

| `t` | `d` | Notes |
|---|---|---|
| `create_room` | `{ "name": string, "players": 2\|3\|4, "rules": RulesConfig? }` | Answered by `room`. Caller becomes host and takes the first seat. **`rules` is optional**; absent means the defaults below, and an explicit `null` is rejected. Section 13.4. |
| `join_room` | `{ "code": string, "name": string }` | Answered by `room` or an `error`. |
| `resume` | `{ "code": string, "seat_token": string }` | Answered by `room` with the full current state. Works in LOBBY, PLAYING and FINISHED. |
| `set_seed` | `{ "client_seed": string }` | Any seated player, **LOBBY only, once per seat**, after that seat has received a `room` frame carrying `chain_commit`. 1 to 64 characters of `[A-Za-z0-9_-]`. Answered by `seat_seed`, broadcast to the room. Section 11. |
| `start_game` | `{ }` | Host only. LOBBY only. Every configured seat filled. |
| `set_players` | `{ "players": 2\|3\|4 }` | Host only. LOBBY only. Not below current occupancy. Re-seats everyone onto the canonical set for the new count and answers with `room`. |
| `roll` | `{ }` | Only the seat whose turn it is, only when the turn is awaiting a roll. |
| `move` | `{ "token": 0..3 }` | Only the seat whose turn it is, only when a roll is pending a selection. |
| `leave_room` | `{ }` | Voluntary. In LOBBY it frees the seat. In PLAYING it does not: the seat remains and is played by the timer. Answered on the leaving socket by the same `player_left` (LOBBY) or `presence` (PLAYING) frame the rest of the room receives, with `re` set. The leaver is told what everyone else was told, not a snapshot of a room it is no longer in. |
| `ping` | `{ }` | Answered by `pong`. |
| `rematch` | `{ }` | Any seated player. FINISHED (asks for a rematch) or a rematch LOBBY (accepts it). Answered by `room`. Section 16. |
| `game_log` | `{ }` | Any seated player, PLAYING or FINISHED. Answered by `game_log` on that socket only. Section 17. |

`name` is a display name: 1 to 24 characters after trimming, no control
characters. It is held in memory for the life of the room and never persisted.

`RulesConfig` carries only the toggles the brief allows:

```json
{ "blocks": true, "capture_bonus": true, "turn_seconds": 45 }
```

Defaults are those values. `turn_seconds` accepts 15 to 120. Any other key is
rejected with `BAD_FIELD` rather than ignored, because silently dropping an
unknown rule toggle produces two clients that believe they are playing
different games.

## 5. Server to client

| `t` | `d` |
|---|---|
| `room` | the full room state, section 6. Sent on create, join, resume, and whenever a client needs resynchronising. |
| `seat_assigned` | `{ "seat": 0..3, "seat_token": string }`. Sent to one client immediately before the `room` that answers its `create_room`, `join_room` or `resume`, and again whenever `set_players` moves that client to a different seat. Section 15. |
| `player_joined` | `{ "seat": int, "name": string }` |
| `player_left` | `{ "seat": int }` |
| `presence` | `{ "seat": int, "connected": bool }` |
| `seat_seed` | `{ "seat": int, "client_seed": string, "origin": "player"\|"server" }`. Broadcast when a seat's seed is fixed. The seed is not a secret. Section 11. |
| `game_started` | `{ "turn": int, "game_id": string, "client_seeds": string }`. **No `seed_commit`** -- the commitment is `chain_commit` and it was published at room creation. Section 11. **A standalone `turn` always follows it**, carrying the first segment's `deadline_ms`, which this frame does not carry. Section 13.1. |
| `rolled` | `{ "seat": int, "value": 1..6, "legal": [int], "deadline_ms": int, "k": int, "reveal": string }`. `legal` is the list of token indices this seat may move with this value. Empty means the turn is about to pass. `k` is the 1-based roll number within this game and `reveal` is `s[k]` as 64 lowercase hex characters; both ship in this same frame, never before it. Section 11. |
| `moved` | `{ "seat": int, "token": int, "from": int, "to": int, "captured": [{"seat":int,"token":int}], "extra_roll": bool }` |
| `turn_passed` | `{ "seat": int, "reason": "no_legal_move"\|"three_sixes" }` |
| `turn` | `{ "seat": int, "deadline_ms": int }` |
| `game_over` | `{ "winner": int, "verify_url": string }`. **No `seed`.** Nothing is withheld until the end any more: every roll's secret was already published in its own `rolled` frame, so a client can finish verifying before this frame arrives. `verify_url` is the permalink for later and for strangers. Section 11. |
| `error` | `{ "code": string, "message": string }`, with `re` set when it answers a specific message. |
| `pong` | `{ }` |
| `game_log` | `{ "game_id": string, "frames": [ ... ] }`, the answer to a `game_log` request, to that socket only. Section 17. |

`deadline_ms` is milliseconds remaining, not an absolute timestamp. Four phones
do not agree on the wall clock and the client must not be asked to reconcile
them.

**Every state-changing push carries `seq` in its `d`, in addition to the fields
listed above.** The table gives each message's own fields and does not repeat
`seq` on every row. Section 6 states that `seq` is mandatory on every
state-changing push and that sentence is the normative one: a client detects a
gap by comparing the `seq` of what arrives against its own, so a delta that
carries no `seq` is a delta the client cannot place, and one such message
desynchronises the client permanently.

Carrying `seq`: `room`, `player_joined`, `player_left`, `presence`, `seat_seed`,
`game_started`, `rolled`, `moved`, `turn_passed`, `turn`, `game_over`.

`seat_seed` is on that list and it matters. A seat's seed is part of the room
state a client renders -- the UI has to show which seats contributed entropy and
which are trusting the server -- so a client that missed one and does not know it
missed one would display a seat's provenance wrongly. That is the same class of
error as a missed `moved`.

Not carrying `seq`: `error` and `pong`, neither of which changes state, and
`seat_assigned`, which is not itself a state change and is always immediately
followed on the same socket by a `room` whose snapshot carries the `seq`.

The value is always read from the room's own counter at the moment the push is
built. It is never counted per connection: one counter per socket looks right in
every single-client test and is wrong the moment two clients share a room, which
is the only case `seq` exists for.

The deltas (`moved`, `rolled`, `turn_passed`) exist so the client can animate.
They are not the source of truth. A client that has missed anything sends
`resume` and takes the `room` snapshot. A client must be correct if it ignores
every delta and renders only snapshots; the deltas are an optimisation.

## 6. The room snapshot

```json
{
  "code": "K7M2QP",
  "state": "LOBBY|PLAYING|FINISHED",
  "host_seat": 0,
  "players": 4,
  "rules": { "blocks": true, "capture_bonus": true, "turn_seconds": 45 },
  "chain_commit": "4b871c47...",
  "chain_index": 0,
  "game_id": null,
  "client_seeds": null,
  "seats": [
    { "seat": 0, "name": "Sam", "connected": true, "tokens": [-1, 0, 14, 57],
      "client_seed": "alice-seed", "seed_origin": "player" }
  ],
  "turn": { "seat": 1, "phase": "await_roll|await_move|finished", "value": 6,
            "legal": [0, 2], "deadline_ms": 41200, "sixes": 1, "k": 12 },
  "winner": null,
  "seq": 118
}
```

- `tokens` is four `progress` integers, exactly as defined in section 1.2 of
  `docs/RULES.md`. There is no second coordinate anywhere in this protocol.
- `seq` increments on every state change. A client that receives a delta whose
  `seq` is not `its own seq + 1` has missed something and must `resume`. This is
  the entire desync detection mechanism and it is why `seq` is mandatory on
  every state-changing push.
- `value`, `legal` and `sixes` are absent when `phase` is `await_roll`.
- `turn.k` is **the number of rolls this game has made so far**: `0` from
  `game_started` until the first roll, and thereafter exactly the `k` of the
  most recent `rolled` frame. The next roll of the game carries `k + 1`. A
  client that reconnects mid-game therefore knows the last chain link that was
  revealed to the room, without replaying anything.

  > **Amended 2026-08-28, run 16, master's ruling.** The bullet shipped saying
  > `turn.k` is "the roll number the **next** roll will carry" *and* that it
  > "equals the `k` of the last `rolled` frame". Those are two different
  > integers one apart and both hands would have implemented a different one.
  > The last-roll reading wins on three counts: the section 6 example carries
  > `"k": 12` on a turn that has already rolled (`value` and `sixes` are
  > present), so 12 is that roll's own number; the same bullet's "`0` in LOBBY"
  > is only consistent with a count of rolls made, since a next-roll counter
  > would read `1` before the first roll; and what a reconnecting client needs
  > in order to check the chain is the last link that was published, not a
  > prediction of the next one. The "next roll" wording is struck.

- `turn.deadline_ms` is milliseconds remaining in the **current turn segment**,
  never an absolute time. A segment starts, and the full `rules.turn_seconds`
  is restored, on every one of these and nothing else: a seat's turn begins, a
  `rolled` frame leaves a legal move pending, and an extra roll is granted. It
  does **not** restart on a `moved` that ends the turn, because the next
  segment belongs to the next seat and starts with that seat's `turn` frame.
  The value is `max(0, turn_seconds * 1000 - elapsed)` measured on the server's
  injected clock, so it is computable in a snapshot whether or not anything is
  scheduled to fire at zero. A server that has not yet implemented expiry still
  reports an honest countdown; it simply lets it reach zero without acting.
- `chain_commit` and `chain_index` are present in every state, including LOBBY,
  because the commitment is published at room creation and is what a player
  checks their seed arrived *after*. `game_id` and `client_seeds` are `null` in
  LOBBY and non-null from `game_started` onward.
- `client_seed` and `seed_origin` are per seat and present in every state. A
  seat that has not set one in LOBBY has `client_seed: null` and
  `seed_origin: null`; both are fixed at `game_started`, at which point
  `seed_origin` is `"player"` or `"server"` and never null again.
- **`seed_commit` is gone, and so is `game_over.seed`.** They were the one-seed
  scheme, which committed the server to a seed it had already chosen freely and
  let it grind for a sequence it liked, and which could not reveal anything
  until the game was over. Section 11 replaces both.

## 7. Errors

Every error is one of these codes. A code is never invented at a call site.

| Code | Meaning |
|---|---|
| `PROTOCOL_VERSION` | `v` is not supported. Connection closed. |
| `BAD_TYPE` | unknown `t`. |
| `BAD_FIELD` | a field is missing, the wrong type, out of range, or unknown. |
| `TOO_LARGE` | frame over 8192 bytes. Connection closed without parsing. |
| `RATE_LIMITED` | see the limits below. |
| `NO_SUCH_ROOM` | the code does not match a live room. Deliberately identical to the response for an expired room, so codes cannot be probed for existence. |
| `ROOM_FULL` | every seat is taken. |
| `ROOM_STARTED` | join attempted on a room that is not in LOBBY. |
| `NOT_HOST` | `start_game` from a non-host. |
| `NOT_ENOUGH_PLAYERS` | `start_game` with an empty seat still in the room, or `set_players` below the current occupancy. |
| `NOT_YOUR_TURN` | an action from a seat that is not on turn. |
| `WRONG_PHASE` | `roll` when a move is pending, or `move` when a roll is pending. |
| `ILLEGAL_MOVE` | the token is not in the `legal` list for the current roll. |
| `BAD_SEAT_TOKEN` | `resume` with a token that matches no seat in that room. |
| `SEED_ALREADY_SET` | a second `set_seed` from a seat that already has one. Section 11. |
| `GAME_OVER` | any action against a FINISHED room, except `rematch`, `resume`, `leave_room`, `game_log` and `ping`. |
| `INTERNAL` | a bug. Logged with the room code and the sequence number. |

Every inbound message is validated in this order and rejected at the first
failure, before any state is touched: size, JSON parse, `v`, `t`, `id` shape,
rate limit, room exists, seat authorised, phase correct, payload fields, rule
legality. Reject, never repair.

**"Before any state is touched" outranks the ordering**, and the two pull
against each other for the messages that carry a room code. For `join_room` and
`resume` the room-exists and seat-authorised steps are not separate checks the
server can run early: they are performed by the registry call, and that same
call is the mutation. Validating the payload after it would mean seating a
player and then rejecting the message that seated them. So for those two, the
whole payload is validated first, and the ladder position of "room exists" is
satisfied by the registry call being the first thing that touches state.

For `start_game`, `set_players`, `leave_room`, `roll` and `move`, which carry no
room code and no seat token, the connection's own stored identity is the room
and seat, so checking it costs nothing and touches nothing. **The identity check
runs before payload validation for those five**, exactly as the ladder reads: a
socket that is in no room gets `BAD_SEAT_TOKEN` for any of them, whatever its
payload looks like.

One field is exempt in every direction. A `code` or `seat_token` whose JSON type
is wrong -- not a string at all -- is `BAD_FIELD` immediately, because no lookup
can be attempted with it. A `code` that is a string but malformed is **not**
pre-validated: it goes to the registry as received, so a malformed code and a
well-formed code for a room that does not exist both come back `NO_SUCH_ROOM`.
A client fuzzing the code space must not be able to tell "badly shaped" from
"shaped fine but nobody is home".

`re` on an outbound frame is only ever an `id` that passed the `id` shape check.
When a message is rejected at or before that step there is no usable `id`, and
the error frame carries no `re`. The server never echoes an unvalidated string
back into a field the envelope rules constrain.

Rate limits, per connection unless stated:

- `create_room`: 5 per hour per IP, and 3 per hour per device. Only an
  attempt the limiter admits counts toward the 5; a `create_room` answered
  `RATE_LIMITED` does not. A host who keeps tapping Create while limited must
  not push their own wait further out. An admitted attempt still counts if a
  later step of the ladder rejects it (`BAD_FIELD`, say), because the rate
  limit runs before payload validation. The per-device half is not
  implemented: nothing in this protocol identifies a device.
- `join_room` and `resume`: 20 per minute per IP. A wrong code counts. This is
  what makes the 32^6 code space unenumerable rather than merely large.
- `game_log`: 2 per minute per connection, then `RATE_LIMITED` (section 17).
- any message: 30 per second, then `RATE_LIMITED`, then close at 60.

"IP" is the immediate TCP peer address, unless that peer is listed in the
server's `TRUSTED_PROXIES`, in which case it is the leftmost address in the
`X-Forwarded-For` header (the peer address when that header is absent or
empty). A header from a peer not in the list is never read. Deployed, every
connection reaches the process from the Docker network gateway, so with an
empty list every player in the world shares one bucket: measured on
2026-09-26, five rooms created from one address made a sixth, from a
different address, answer `RATE_LIMITED`. The reverse proxy in front of
both hostnames replaces any `X-Forwarded-For` a client sends (measured the
same night: five distinct forged values did not buy a sixth room), which is
what makes trusting the gateway safe. `deploy/ludo/README.md` has the values.

### 7.1 Close codes

Four errors close the connection. Until now this document said "connection
closed" without saying with what code, and that gap produced a live defect: the
server was written with the RFC 6455 codes 1008 and 1009, which are correct on
the wire and are rejected by the Dart `web_socket` package underneath
`web_socket_channel`. `checkCloseCode` there permits only **1000 or the range
3000 to 4999**. The rejection surfaces as an asynchronous error on the sink,
which no caller sees, so the socket is simply never closed and the client is
left holding an open connection the server has stopped answering. A player on a
phone waits on that socket forever rather than reconnecting.

The close code is therefore part of the protocol and is pinned here. The
4000-4999 range is reserved by RFC 6455 for application use, which is what these
are, and it is inside what the library accepts:

| Close code | Sent when | Error frame that precedes it |
|---|---|---|
| `4001` | frame over 8192 bytes | `TOO_LARGE` |
| `4002` | unsupported `v` | `PROTOCOL_VERSION` |
| `4003` | the 60-per-second ceiling | `RATE_LIMITED` |
| `4004` | this seat was taken over by a newer socket | `BAD_SEAT_TOKEN` |

Rules that go with them:

- The error frame is sent **before** the close, always, so a client that reads
  the reason does not have to infer it from the code alone.
- A close that fails must be **observable**. Awaiting the sink's close future is
  not enough on its own, because the failure above arrives as an unhandled
  asynchronous error rather than as a rejected future the caller is holding. A
  server that believes it closed a connection it did not close is worse than one
  that never tried.
- No other code is used. A close for any other reason is a defect, not a new
  code invented at the call site.

## 8. Reconnection

The seat survives the socket. This is a feature, not a recovery path, and it is
tested in the simulator gate with one client killed and with two killed at once.

1. On taking a seat the client receives `seat_assigned` and stores `code` and
   `seat_token` in device storage that survives a process kill.
2. On any disconnect the server marks the seat not connected and pushes
   `presence` to the others. The seat stays in the game. Its turns are played by
   the timer under rule 15 of `docs/RULES.md`.
3. On reconnect the client opens a socket and sends `resume` with `code` and
   `seat_token`. It does not send `join_room`; joining is for new players and
   would be rejected with `ROOM_STARTED`.
4. The server answers with `seat_assigned` and then the full `room` snapshot
   (section 15). The client takes its seat from that `seat_assigned`, never from
   the one it stored, and stores it again. The client discards its
   local state entirely and renders the snapshot. It does not attempt to
   reconcile, replay or animate the gap. The **other** sockets are told the seat
   is back with a `presence` carrying `connected: true`, but only when the
   resume actually flipped the seat; a takeover of a seat that was already
   connected (rule 6 below) broadcasts nothing. Section 13.2.
5. If the game ended while the client was away, the snapshot has `state`
   `FINISHED` and a `winner`, and that is how the player learns the result.
6. A second socket presenting a valid `seat_token` for a seat that is already
   connected takes over the seat and the older socket is closed with
   `BAD_SEAT_TOKEN`. Last writer wins, because the common cause is the same
   person's phone reconnecting before the server noticed the old socket died.

## 9. Deep links

`https://<domain>/r/<CODE>` is the shareable link and the room code is the last
path segment, uppercase. It is a verified Android App Link, so it opens the app
rather than a browser.

Without the app installed it must degrade honestly: the URL serves a small page
that says what the game is, links to Play, and shows the code in copyable text
so it can be pasted after install. The page carries no tracker, no analytics and
no third-party asset, because the Data safety declaration for this app says
nothing is collected and that has to stay true of the web page too.

The `assetlinks.json` served from `https://<domain>/.well-known/assetlinks.json`
carries the SHA-256 of the **app signing key**, which with Play App Signing is
the key Google holds, not the upload key. Putting the upload key fingerprint
there is the standard way this fails, and it fails silently: links simply open
in the browser.

## 10. What the client may not do

The client never rolls a die, never decides legality, never advances a turn,
never computes a capture and never reports a result. It sends an intention and
renders what comes back.

It may compute the `legal` set locally to grey out tokens before the server
answers, and it may animate optimistically. It must correct itself to the
server's message without argument when the two differ, and it must never
suppress or delay a server message because it disagrees with it.

## 11. Verifiable dice -- the 2026-08-28 amendment

`docs/FAIRNESS.md` is the scheme and its test vectors. This section is the wire
form of it, and where the two disagree about a field name or a frame, **this
file wins for the wire and FAIRNESS.md wins for the cryptography**.

### 11.1 What the ordering has to prove

The whole security argument is an ordering, and it must be provable from a
transcript a client kept, not promised in a document:

    chain_commit published   ->   player seeds arrive   ->   play
    (room creation)               (LOBBY, set_seed)          (rolled frames)

The server commits to all 4096 future secrets before it has seen a single
player seed, so it cannot grind a chain to suit the seeds; the players' seeds
land afterwards, so the server cannot choose them; and each `s[k]` is published
in the same frame as the roll it produced, so no player can predict a roll and
no player can influence one.

A client verifying offline needs nothing but the frames it already received.
That is the point of putting `reveal` in `rolled` rather than behind a link.

### 11.2 Frame-by-frame

**`room`** carries `chain_commit` (64 lowercase hex characters, `s[0]`) and
`chain_index` (integer, `0` for the first chain of the room) from the moment the
room exists. Both are in the LOBBY snapshot. A client that joins later gets the
same values, and it MUST NOT accept a `chain_commit` that changes for a given
`chain_index` within one room; that is a forged roll and the client shows it as
one.

**`set_seed`** (client to server), **LOBBY only, once per seat.** The rejection
ladder, in order, so an implementation does not invent one:

| Situation | Code |
|---|---|
| the room does not exist, or no longer does | `NO_SUCH_ROOM` |
| room exists but is not in LOBBY | `WRONG_PHASE` |
| socket holds no seat | `BAD_SEAT_TOKEN` |
| `client_seed` absent, not a string, empty, over 64 characters, or containing anything outside `[A-Za-z0-9_-]` | `BAD_FIELD` |
| this seat already has a seed | `SEED_ALREADY_SET` |

`WRONG_PHASE` precedes the seat check here, unlike the five messages in section
7 whose identity check runs first, because a `set_seed` arriving after
`start_game` is a client racing the host rather than a client in no room, and
telling it "wrong phase" is the accurate answer. Say it, do not repair it.

> **The `NO_SUCH_ROOM` row was added 2026-08-28, run 15, master's ruling.** The
> table shipped without it and the implementer, correctly, refused to invent an
> answer: it reported the gap and folded a vanished room into `WRONG_PHASE`
> because a room that does not exist is certainly not a room in LOBBY. That
> reasoning is sound and the ruling still goes the other way, for two reasons.
>
> The first is consistency. A reaped room already answers `NO_SUCH_ROOM` on all
> four of the other entry points, and the registry has a test pinning exactly
> that. One message answering differently about the same fact is the kind of
> inconsistency that gets "fixed" later by someone who does not know which of
> the two was deliberate.
>
> The second is what the client does next, which is the part that matters at
> 2am. `WRONG_PHASE` tells a client the game moved on without it, and the
> reasonable response is to wait for the `game_started` it must have missed.
> That push is never coming, because there is no room. `NO_SUCH_ROOM` tells it
> the truth: go back to the join screen. Two error codes that differ only in
> which wrong thing the client then does are not interchangeable.
>
> There is no existence leak either way. A socket that reaches this rung is
> holding a seat token for that room, so it already knows the room existed.

**`seat_seed`** (server to client) is broadcast to the whole room when a seat's
seed is fixed: `{ "seat": int, "client_seed": string, "origin":
"player"|"server" }`, plus `seq`. Fixed happens twice: on an accepted
`set_seed`, and at `start_game` for every seat that sent none, which the server
gives a 16-byte hex seed with `origin: "server"`.

**The UI must show a `"server"` seat as not having contributed entropy.** It is
still fully auditable; it is a seat that chose to trust the server, and a player
is entitled to see which of their friends did that.

> **This frame is named `seat_seed`, not `seed_set` as `docs/FAIRNESS.md`
> section 4 calls it. Deliberate, master's decision, 2026-08-28.** `set_seed`
> and `seed_set` differ only by a transposition, they travel in opposite
> directions, and both would appear as adjacent cases in the same `switch` on
> `t`. A typo between them would not fail to compile and would not fail a
> casual test. Nothing about the cryptography changes. `seat_seed` also reads
> correctly, because the frame is about a seat.

**`game_started`** gains `game_id` (16 lowercase hex characters, server
generated, the key of the verification permalink and **not** the room code,
which is reissued after 24 hours) and `client_seeds` (the frozen combined
string: seats in ascending index, `seat:seed`, joined by `|`, for example
`0:alice-seed|2:bob-seed`). It **drops `seed_commit`**. `chain_commit` is not
repeated here; it was in `room` and it has not changed.

`client_seeds` is frozen at this instant and is a literal string on the wire
rather than something the client reassembles from the `seat_seed` frames it
happened to receive. It is an input to every HMAC, so a client that rebuilt it
with a different separator, a different ordering, or a seat it missed would
compute every face wrong and conclude the server cheated. Ship the exact bytes.

**`rolled`** gains `k` and `reveal`. `k` is 1-based within the game and
increments by exactly one per roll. `reveal` is `s[k]`, 64 lowercase hex
characters. The client verifies `SHA-256(reveal) == ` the previous reveal, and
the first one against `chain_commit`.

**There is no `die` field**, though FAIRNESS.md section 4 lists one. `rolled`
already carries `value`, which is the face. Two fields that must always agree is
a desync waiting to be written, and the one that already exists is the one every
other part of this protocol reads. **`value` is the die.**

For the HMAC of FAIRNESS.md section 2.3, **Ludo always uses die index `d = 0`**,
so the message is `"<game_id>|<client_seeds>|<k>|0"`. Backgammon will ask for
`d = 0` and `d = 1` off the same reveal; that is backgammon's protocol, not
this one, and the shared `packages/fair_dice` already takes `d` as a parameter.

**`game_over`** drops `seed` and gains `verify_url`, the absolute
`https://provefair.app/v/<game_id>`. It is a convenience for a stranger and for
later. **A client must never need it to verify**; everything required was in the
frames.

### 11.3 What the server must not do

- Never send `reveal` for a roll before that roll's result. One early reveal
  destroys the scheme for every roll after it, because the chain runs backwards.
- Never reuse a chain across games. A new `game_id` gets a new chain and a new
  `chain_commit`, published in `room` before the game starts.
- If a game exceeds `N = 4096` rolls, start a second chain, increment
  `chain_index`, and publish the new `chain_commit`. The 40-game golden corpus
  tops out at 945 intentions so this never happens in practice, but a silent
  wrap is indistinguishable from a forgery and must be impossible rather than
  unlikely.
- Never accept a `set_seed` after `start_game`, and never let a seat's seed
  change once fixed. The seed is an input to every face of the game.

### 11.4 What this obsoletes

`seed_commit`, `game_over.seed`, and the engine's per-game seed as a source of
dice. The engine already stopped drawing faces on run 11 -- `RollIntention`
carries the face and the engine validates `1..6` -- so the server is now the only
thing that decides a face, which is exactly where a verifiable scheme needs it.

## 12. The turn loop, frame by frame

Master-written 2026-08-28, run 16, for order 008 and its blind test half. Every
statement here is normative. Where this section and section 5's table describe
the same frame, section 5 gives the fields and this section gives the ordering.

### 12.1 `roll`

The rejection ladder, in order, first failure wins, nothing is touched before a
rejection:

| Situation | Code |
|---|---|
| the room does not exist, or no longer does | `NO_SUCH_ROOM` |
| the socket holds no seat in that room | `BAD_SEAT_TOKEN` |
| the room is FINISHED | `GAME_OVER` |
| the room is in LOBBY | `WRONG_PHASE` |
| the sender is not the seat on turn | `NOT_YOUR_TURN` |
| the turn is awaiting a move, not a roll | `WRONG_PHASE` |

`NOT_YOUR_TURN` precedes the phase check, and that ordering is deliberate: a
player who is not on turn learns only that, and is not told which phase the
seat on turn happens to be in. It is not a secret worth defending, but two
implementations that order these differently produce two different error codes
for the same wire input, and a conformance test cannot pin both.

On acceptance the server, in this order:

1. increments the game's roll counter to `k = turn.k + 1`;
2. takes `reveal = chain.reveal(k)`, 64 lowercase hex;
3. takes `value = drawDie(reveal, game_id, client_seeds, k, 0)`, which is
   `packages/fair_dice`'s function and is not reimplemented here;
4. applies `RollIntention(seat, value)` to the engine;
5. broadcasts one `rolled` carrying `seat`, `value`, the engine's `legal`,
   `deadline_ms`, `k`, `reveal` and `seq`.

**The chain link is read once and published in that same frame.** There is no
path on which `reveal` is computed and the frame is not sent, and no path on
which `k` advances without a `rolled`. A `roll` rejected by the ladder above
advances nothing: the counter, the chain and the engine are all untouched, so a
client may retry a rejected `roll` and receive the same `k` it would have had.

If the engine reports the turn ended with no legal move, a `turn_passed` with
`reason: "no_legal_move"` follows the `rolled`, then a `turn` for the next
seat. If it ended on the third six, the same, with `reason: "three_sixes"`. In
both cases the `rolled` is still sent first and still carries its `reveal`: the
roll happened, and a roll that is not published is a hole in the chain.

### 12.2 `move`

The same ladder, with `WRONG_PHASE` when the turn is awaiting a roll rather
than a move, and `ILLEGAL_MOVE` when `token` is not in the current `legal`
list. `token` absent, not an integer, or outside `0..3` is `BAD_FIELD`, and it
is checked before legality, because a malformed field is not an illegal move.

On acceptance the server broadcasts one `moved` carrying `seat`, `token`,
`from`, `to`, `captured`, `extra_roll` and `seq`, built from the engine's own
events and from nothing else. `captured` is the list of `{seat, token}` the
engine reported captured by this move, in the order it reported them, and is an
empty list when there were none. `extra_roll` is true exactly when the engine
granted one, whether for a six or for a capture.

Then, in order, whichever apply:

- if the game is now won: `game_over` with `winner` and `verify_url`, and the
  room moves to FINISHED. No `turn` frame follows a `game_over`.
- else if the turn ended: `turn` for the seat that now holds it.
- else (an extra roll, or a move that left the same seat on turn): `turn` for
  the same seat, so every client's countdown restarts from one frame it can see
  rather than from a rule it has to infer.

### 12.3 What must be true of every one of these frames

- Every frame in this section carries `seq`, taken from the room's counter at
  the moment the frame is built, and the counter advances by exactly one per
  frame. Three frames from one `move` carry three consecutive `seq` values.
- Every frame is broadcast to **every connected socket in the room**, including
  the one that sent the message that caused it. The sender's copy carries `re`;
  the others do not. A sender that had to special-case its own action would be
  a second code path for the same state change, and the second path is the one
  that drifts.
- A `roll` or `move` from a disconnected-but-seated player is impossible by
  construction, since it arrives on a socket, but the seat being marked
  disconnected is not itself grounds for rejection: a socket that has resumed
  the seat is the seat.
- The engine is the only thing that decides legality, capture, extra rolls and
  the winner. The server decides the face, the ordering and the wire shape. No
  rule from `docs/RULES.md` is reimplemented in the server.

## 13. Four rulings, 2026-08-28

The four-client simulator (order 014) read this document, found four places
where it did not say enough to write a client against, reported them, and
invented around none of them. That was the correct behaviour and these are the
answers. Each ruling says whether the server already does this or whether the
code has to change.

### 13.1 A standalone `turn` follows `game_started`. Always.

**The spec contradicted itself and this resolves it.** Section 6 says a turn
segment starts, and `rules.turn_seconds` is restored, when "a seat's turn
begins", and that the next segment "starts with that seat's `turn` frame". The
first seat's turn begins at `game_started`, and `game_started` carries
`{ turn, game_id, client_seeds }` with **no `deadline_ms`**. So under the old
text the first turn of every game was the one segment in the game with no frame
announcing it, and the sentence deriving `deadline_ms` from the `turn` frame was
false for exactly that segment.

The order is therefore, on `start_game`:

    seat_seed (one per server-seeded seat, in seq order)
    game_started
    turn                              <- new, seat == game_started.turn

`turn` is the single uniform signal that a turn segment has begun, with no
exception at the start of the game. A client keeps one handler for "a turn
began" rather than two, and the one that fires once per game is not the one that
gets tested least and drifts.

`game_started.turn` is kept and is not redundant: it tells a client the game
began and who moves first, which it needs to render the board before it renders
a timer. The `turn` frame adds the deadline, which `game_started` has no
business carrying: `deadline_ms` is milliseconds remaining, computed at send
time, and `game_started` is built once and broadcast to every socket from one
shared map.

**The `turn` frame carries its own `seq`, one greater than `game_started`'s.**
Section 12.3 says every frame carries `seq` and that the counter advances by
exactly one per frame. The opening `turn` is not exempt and does not share
`game_started`'s value. The reason is the one 13.2 gives below for the opposite
case: a frame that repeats a `seq` the room has already used reads to a client
as a repeat rather than an advance, and makes a correct client resynchronise for
no reason. So `start_game` advances the room counter twice -- once for the game
starting, once for the opening turn segment -- and the frames go out in that
order, each carrying the value it advanced to.

The full order on an accepted `start_game`, with `seq` advancing by one at every
step:

    seat_seed (one per server-seeded seat, each at its own seq)
    game_started                      seq = n
    turn                              seq = n + 1, seat == game_started.turn

`deadline_ms` on that frame is measured from the segment the registry already
starts at `start_game`, not from send time of a later frame.

**The server does this. Implemented and proved.** `_handleStartGame` builds the
opening `turn` with `buildTurn(seat: room.game.currentSeat, deadlineMs:
ok.nextDeadlineMs, seq: ok.turnSeq)` and sends it to the whole room
(`packages/ludo_server/lib/src/connection.dart:505-518`), with `turnSeq` and
`nextDeadlineMs` computed by the registry rather than recomputed at send time
(`registry.dart:93-123`). Its blind conformance half is
`packages/ludo_server/test/turn_after_start_test.dart`, and
`dice_steering_test.dart` and `fairness_lobby_test.dart` both consume the frame
in their own sequences.

> **Corrected 2026-08-29, run 27.** This paragraph said "The server does not do
> this yet ... it needs its own order and its own blind test half" and kept
> saying it after orders 061 and 062 had delivered exactly that. A section that
> declares a defect the code no longer has is worse than one that says nothing:
> run 27 wrote it into a work order's frozen declaration as a live constraint,
> on this document's authority, before measuring the handler. Measure the code,
> then trust the prose.

### 13.2 `presence` broadcasts on `resume` only when the seat actually flipped

Section 8 said a disconnect pushes `presence` to the others and never said what
a reconnect pushes, which left the room able to learn that a seat went away and
never learn it came back.

The ruling: **`presence` with `connected: true` is broadcast to the other
sockets when, and only when, the resume actually changed the seat from not
connected to connected.** A resume that takes over a seat which was already
connected -- section 8 rule 6, the same person's phone reconnecting before the
server noticed the old socket died -- broadcasts nothing.

The reason is `seq`, and it is not a micro-optimisation. A takeover flips
nothing on the seat, so the room counter does not advance. Broadcasting anyway
would put a `seq` on the wire that the room has already used, which reads to a
client as a repeat rather than an advance and triggers a needless `resume`
against a socket that was merely flapping. A frame that makes correct clients
resynchronise for no reason is worse than no frame.

The resuming socket itself gets the full `room` snapshot with `re`, per section
8 step 4, and does not also get the `presence`. It is not news to itself.

**The server already does exactly this**, at `connection.dart`'s resume handler,
guarded on the registry's own reconnected flag. This section documents behaviour
that already exists and was never written down.

### 13.3 There is no such thing as two things happening at the same moment

The simulator's `double-drop` scenario asks what "two clients drop at the same
moment" means. At the protocol level it means nothing, and that is the ruling.

**Every state change in a room is serialised through that room's single `seq`
counter.** Two sockets closing microseconds apart are two closes, processed one
after the other, producing two `presence` frames at two consecutive `seq`
values. There is no combined frame, no ordering guarantee between the two beyond
that they are ordered, and no way for a client to tell a simultaneous drop from
two drops in quick succession. It does not need to.

"At the same moment" is therefore a **test-harness** definition, not a protocol
one, and it belongs in `docs/SIMULATOR.md` where it already is: both sockets are
closed before either reconnect begins, and the two reconnects are then raced
concurrently rather than run in sequence. That is what makes the scenario prove
more than running `reconnect` twice -- it exercises two seats mid-resume against
one room counter -- and it is a statement about the test, not about the wire.

A client may make no assumption about the relative order of two `presence`
frames for two different seats beyond their `seq`.

### 13.4 `rules` is optional on `create_room`; absent means the documented defaults

Section 4's table lists `create_room` as `{ name, players, rules }`, which reads
as three required fields, while the paragraph under `RulesConfig` says "Defaults
are those values", which only means something if the object can be left out.

The ruling, in full, because the middle case is the one that bites:

- **`rules` absent** -- accepted, and the room gets `blocks: true`,
  `capture_bonus: true`, `turn_seconds: 45`.
- **`rules` present with a subset of keys** -- accepted; the keys given are
  taken and the rest default individually.
- **`rules` present and explicitly `null`** -- **rejected** with `BAD_FIELD`. An
  explicit null is a client that thinks it is sending something, and it gets no
  exemption from the rule below.
- **`rules` carrying any key other than `blocks`, `capture_bonus`,
  `turn_seconds`** -- rejected with `BAD_FIELD`, never ignored. Section 4
  already says why: silently dropping an unknown rule toggle produces two
  clients that believe they are playing different games.

**The server already does exactly this**, in `connection.dart`'s rules parser.
This section makes the table agree with it.

## 14. Two rulings on the snapshot's `turn`, 2026-08-29

Both were found by reading `lib/src/snapshot.dart` against section 6 rather
than by reading section 6 alone, and both matter to the client decoder that is
about to be written: a decoder built strictly on section 6 as it stood would
reject the snapshot of a finished game, which is the exact snapshot a player who
was away when the game ended receives on `resume` under section 8 rule 5.

### 14.1 `turn.phase` has a third value, `finished`

Section 6's example carried `"await_roll|await_move"` and that list is
incomplete. `engine.GamePhase` has three members and `snapshot.dart:118-127`
maps all three onto the wire, so a room in state `FINISHED` serves a `turn`
object whose `phase` is the string `finished`.

That is the right behaviour and it is not being changed. The snapshot describes
the game as it stands, and a game that has ended is in a real phase, not in an
absent one. What was wrong is section 6's enumeration, which is now corrected in
place.

A `turn` carrying `phase: "finished"` follows the same field rules as
`await_roll`: `value`, `legal` and `sixes` are absent, because
`_turnSnapshot` adds them only under `await_move`. `deadline_ms` and `k` are
present, as they are in every phase.

**A client must accept all three values.** Rejecting `finished` costs a player
the one frame that tells them how the game they missed came out.

### 14.2 `turn` is null before `start_game`, and only there

`_turnSnapshot` returns null exactly when `room.game` is null, and `room.game`
is set at `start_game` and never cleared. So:

- **LOBBY** -- `turn` is `null`. There is no turn, and there is no honest
  integer to put in `seat`.
- **PLAYING** -- `turn` is an object, `phase` is `await_roll` or `await_move`.
- **FINISHED** -- `turn` is an object, `phase` is `finished`. It is **not**
  null. The losing readings here are equally plausible from section 6's text
  alone, which is why this is written down rather than left to two hands to
  guess at separately.

`winner` moves the other way and is the companion field: `null` in LOBBY and
PLAYING, an integer seat in FINISHED.

## 15. A seat number can change in the lobby, 2026-09-27

`set_players` re-seats everyone onto the canonical set for the new count
(section 3): `[0, 2]` for two players, `[0, 1, 2]` for three, `[0, 1, 2, 3]`
for four, filled in the order of the old seat numbers. Until this ruling a
client learned its seat exactly once, from `seat_assigned`, and nothing ever
told it the number had moved. The snapshot has no "you" field. So a host at
seat 0 with one friend at seat 1 of a four-seat room who shrinks the room to
two moves that friend to seat 2, and the friend's phone goes on believing it is
seat 1: it never sees its own turn, and a later `resume` restores the wrong
seat. It was unreachable only because no client offered `set_players`.

The ruling:

1. **After a successful `set_players`, every connected seat whose number
   changed receives `seat_assigned` with its new `seat` and its unchanged
   `seat_token`, before the `room` that carries the new seating.** For the
   host that is before the `room` reply; for everyone else, before the `room`
   broadcast. A seat whose number did not change receives no `seat_assigned`.
   A seat that is not connected receives nothing then and learns its seat on
   `resume` (rule 2).
2. **`resume` is answered with `seat_assigned`, then `room`**, on the resuming
   socket, always, whether or not the seat moved while it was away. This covers
   the seat that was disconnected during a re-seat and a stored seat number
   that is stale for any other reason. Section 8 rule 4 now says so.
3. **The seat token never changes.** Only the number does. The token is the
   identity; the number is where that identity sits at the table.
4. `seat_assigned` still carries no `seq` (section 5): it is not a state change
   on its own and is always followed on the same socket by a `room` whose
   snapshot carries the `seq`.
5. **A client treats every `seat_assigned` as the truth about its own seat**,
   at any point in the connection, and overwrites what it held, including the
   seat it passed to `resume`.

Implemented in PR #75 (`2e26b91`): rules 1 and 2 in the server's
`_handleSetPlayers` and `_handleResume`, rule 5 in the client's
`RoomConnection` and `RoomController`. The tests that hold them are
`packages/ludo_server/test/reseat_seat_assigned_test.dart` and
`packages/ludo_client/test/net/room_controller_reseat_test.dart`.

## 16. Rematch, 2026-10-01

The product owner's note of 2026-09-30: after a game, the same friends play
again with one tap (`bin/game-doctrine.md` P5, P6). Until now FINISHED was
terminal and a rematch meant a new room, a new code and a new invite. This
section reopens the same room for a new game. It reuses LOBBY, `set_seed`
and `start_game` as they are, so the fairness ordering of section 11.1 holds
for the second game exactly as for the first.

### 16.1 The message

`rematch` `{ }`, client to server, from any seated player. No payload field is
read; any key in `d` is `BAD_FIELD` like every other message.

Validation ladder, identity first as for the five messages in section 7:

| Situation | Code |
|---|---|
| socket holds no seat | `BAD_SEAT_TOKEN` |
| the room no longer exists (reaped) | `NO_SUCH_ROOM` |
| room in PLAYING | `WRONG_PHASE` |
| room in a LOBBY that is not a rematch lobby (`rematch` is null) | `WRONG_PHASE` |
| `d` carries any key | `BAD_FIELD` |

### 16.2 The first `rematch`: FINISHED to LOBBY

Accepted in FINISHED from any seat, connected or just resumed. In one step,
before anything is sent:

1. `state` becomes LOBBY. `game_id`, `client_seeds`, `turn` and `winner`
   become null. Every seat's `tokens` become `[-1, -1, -1, -1]` and its
   `client_seed` and `seed_origin` become null.
2. **A new chain.** `chain_index` increases by one and `chain_commit` is the
   commitment of a chain generated fresh from the CSPRNG for this game, never
   derived from any earlier chain of the room (section 11, "never reuse a
   chain across games"). The previous game's record stays at its own
   `/v/<game_id>` and is not touched.
3. `rematch` in the snapshot becomes `{ "by": <seat>, "ready": [<seat>] }`:
   the requester is ready.
4. The room's 60-minute total lifetime (section 3) restarts from this
   moment, so a second game is not reaped half way through. The LOBBY rules
   of section 3 apply from here (reaped after 10 minutes with no connected
   client).
5. `seq` advances by one and the `room` snapshot is broadcast to every
   connected seat; the requester's copy carries `re`.

`players`, `rules`, `host_seat`, every seat's number, name and
`seat_token` are unchanged.

### 16.3 Accepting: `rematch` in a rematch LOBBY

From a seat not yet in `rematch.ready`: the seat is added, `seq` advances,
`room` is broadcast (the sender's copy with `re`). From a seat already
ready: nothing changes, `seq` does not advance, and only the sender gets the
current `room` with `re`. A double tap is not an error.

A seat that does not want to play again sends `leave_room`, which in LOBBY
frees the seat as it always has (`player_left` broadcast). A seat that never
answers stays seated and not ready.

### 16.4 Starting the rematch

- **Everyone accepted.** When every seat occupied at the moment of an
  accepted `rematch` is in `rematch.ready`, at least two seats are occupied,
  and every one of them is connected, the
  server starts the game itself, exactly as an accepted `start_game` from
  the host would (sections 11.2 and 13.1, the same frame order and the same
  `seq` steps), immediately after broadcasting the `room` that recorded the
  last acceptance. Two friends: one tap each, no third tap.
- **Not everyone.** The host may send `start_game` once at least two seats
  are ready. On that `start_game`, before the normal start order: every
  occupied seat that is not ready is removed as if it had sent `leave_room`
  (one `player_left` each, ascending seat order, `seq` +1 each); `players`
  becomes the number of ready seats; the remaining seats are re-seated onto
  the canonical set for that count with section 15 rule 1 (`seat_assigned`
  to each seat whose number changed, then the `room`); then the start order
  runs. Fewer than two ready: `NOT_ENOUGH_PLAYERS`, nothing changes.
- `set_players` in a rematch LOBBY is `WRONG_PHASE`: the ready list decides
  the count.
- `rematch` becomes null again in the `room` and frames the start sends;
  from `game_started` on the room is an ordinary PLAYING room.

### 16.5 Seeds in a rematch LOBBY

`set_seed` is accepted once per seat **per `chain_index`**. A seat that set
a seed in the first game may set one again for the new chain;
`SEED_ALREADY_SET` applies only to a second seed within the same
`chain_index`. A client MUST check that the `chain_commit` it is shown for
the new `chain_index` arrived before it sent its seed, as in section 11.2.

### 16.6 The snapshot field

`rematch`: null, or `{ "by": 0..3, "ready": [int] }` with `ready` in
ascending seat order and always containing `by` unless `by` has since left.
Present in every state; non-null only in a rematch LOBBY. A client that
resumes into a rematch LOBBY sees it like any other field.

### 16.7 What the client does with it (informative)

The end card's Rematch button sends `rematch`. A `room` with state LOBBY and
a non-null `rematch` that does not list my seat is shown on the end card as
"<name of `by`> wants a rematch" with one tap that sends `rematch`; once my
seat is in `ready` the client shows the lobby. A FINISHED room with no
rematch after 10 minutes is reaped as before; the end card says so when the
`rematch` answer is `NO_SUCH_ROOM`.

### 16.8 Tests this section requires before it is implemented

Server: FINISHED to LOBBY field by field (16.2 items 1 to 5); `chain_commit`
differs and `chain_index` is +1; the old `/v/<game_id>` record unchanged;
accept, double accept (no `seq` change); auto-start when all ready and
connected, and no auto-start when one ready seat is disconnected; host start
with a non-ready seat (player_left, re-seat, `seat_assigned`); fewer than two
ready; `set_players` refused; `set_seed` again for the new chain and refused
twice within it; every row of 16.1; the 60-minute clock restarted.
Simulator: full-game, rematch, full-game, both records fetched and verified,
different `game_id` and `chain_commit`.

### 16.9 Rulings after the first implementation, 2026-10-01

Four cases the text above left open, found by the first server
implementation. Each is a test before it is code.

1. **A seat removed by a host-forced start is gone, exactly as after
   `leave_room`.** If its socket is connected it receives the `player_left`
   that names its own seat, like every other connected seat, and nothing
   further from the room. Its `seat_token` no longer names a seat: any
   later frame on that socket that needs a seat, and any `resume` with that
   token, is `BAD_SEAT_TOKEN`.
2. **The host's `start_game` in a rematch LOBBY counts as the host's
   acceptance.** If the host is not in `rematch.ready`, it is added first,
   without a broadcast or a `seq` step of its own, and the count of ready
   seats is checked after that. The host is never removed by its own
   `start_game`.
3. **The re-seat step is sent only when it changes something.** If no seat
   was removed, there is no `player_left`, no `seat_assigned` and no extra
   `room`: the start order runs directly. If at least one seat was removed,
   the `room` that carries the new `players` and seating is sent with its
   own `seq` step even when no seat number changed (then no `seat_assigned`
   goes out).
4. **A rematch LOBBY takes `join_room` like any LOBBY.** A seat freed by
   `leave_room` can be taken by a new joiner by code (lowest free seat of the
   canonical set for `players`, section 3). The joiner is not ready; it
   accepts with `rematch` like anyone else. The auto-start set is the seats
   occupied when an accept arrives (16.4), so a seat that left never blocks
   it and a seat that joined is waited for. Auto-start is evaluated only on
   an accepted `rematch`, never on `leave_room`, `join_room` or `resume`.

## 17. `game_log`: the current game's frames on request, 2026-10-10

Section 8 answers a `resume` with a snapshot and replays nothing, which is
right for playing on. It is not enough for the end card's numbers (doctrine
P6), which a client computes on the device from the game's own frames: a
socket that was down for one push has a hole, and an app that was killed
has no frames at all. This message lets a seated client ask for the frames
it may have missed. It adds nothing a seat has not already been sent.

1. **Request.** `game_log` `{ }`, with an `id`. Accepted from a seated
   socket when the room is PLAYING or FINISHED. In LOBBY (including a
   rematch LOBBY): `WRONG_PHASE`. From a socket that holds no seat in the
   room: the same error `roll` gets from such a socket. Validated in the
   section 7 order like any other message.
2. **Answer.** On the requesting socket only, `game_log`
   `{ "game_id": string, "frames": [ ... ] }` with `re` set to the
   request's `id`. `game_id` is the current game's. `frames` is every push
   the room broadcast for the current game, from its `game_started` up to
   the moment of the answer, in ascending `seq`, each as an object
   `{ "t": string, "d": object }` holding exactly the type and the data a
   socket attached for the whole game received for that push (`seq`
   included, `re` never). Frames sent to one socket only (`seat_assigned`,
   errors, `pong`, a `room` that answers a request, another `game_log`) are
   not in it.
3. **No state change.** It carries no `seq` of its own, changes nothing in
   the room and is never broadcast.
4. **Rate.** At most 2 per minute per connection, then `RATE_LIMITED`
   (counted before the room checks, like the other per-message limits).
   An answer can be large, several hundred frames for a long game; the
   8192-byte cap of section 7 is on inbound frames only.
5. **Lifetime.** The log belongs to the room's current game: a new
   `game_started` (a rematch) starts a new one, and it goes when the room
   goes.
6. **Nothing new is revealed.** Every frame in it has already been sent to
   every connected seat. Section 11.3 holds: no face before its roll, no
   chain reveal ahead of `turn.k`.
7. **Tests this section requires before it is implemented.** A seat that
   stayed connected for a whole game and records every push from
   `game_started` gets exactly the same list, frame for frame, from a
   `game_log` sent by another seat after `game_over`; the same mid-game;
   `WRONG_PHASE` in LOBBY; an unseated socket refused; the third request
   in a minute `RATE_LIMITED`; after a rematch's `game_started` the log
   holds the new game only; the answer reaches the requester and no other
   socket.
