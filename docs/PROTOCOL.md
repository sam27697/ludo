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
  `ABCDEFGHJKLMNPQRSTUVWXYZ23456789` — 32 symbols. `0`, `O`, `1` and `I` are
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
- **FINISHED.** Terminal. The final state is served to anyone reconnecting, for
  10 minutes, then the room is reaped.
- A room in any state is reaped 60 minutes after creation regardless. A LOBBY
  with no connected clients is reaped after 10 minutes.
- A reaped room's code is not reissued for 24 hours.

## 4. Client to server

| `t` | `d` | Notes |
|---|---|---|
| `create_room` | `{ "name": string, "players": 2\|3\|4, "rules": RulesConfig }` | Answered by `room`. Caller becomes host and takes the first seat. |
| `join_room` | `{ "code": string, "name": string }` | Answered by `room` or an `error`. |
| `resume` | `{ "code": string, "seat_token": string }` | Answered by `room` with the full current state. Works in LOBBY, PLAYING and FINISHED. |
| `set_seed` | `{ "client_seed": string }` | Any seated player, **LOBBY only, once per seat**, after that seat has received a `room` frame carrying `chain_commit`. 1 to 64 characters of `[A-Za-z0-9_-]`. Answered by `seat_seed`, broadcast to the room. Section 11. |
| `start_game` | `{ }` | Host only. LOBBY only. Every configured seat filled. |
| `set_players` | `{ "players": 2\|3\|4 }` | Host only. LOBBY only. Not below current occupancy. Re-seats everyone onto the canonical set for the new count and answers with `room`. |
| `roll` | `{ }` | Only the seat whose turn it is, only when the turn is awaiting a roll. |
| `move` | `{ "token": 0..3 }` | Only the seat whose turn it is, only when a roll is pending a selection. |
| `leave_room` | `{ }` | Voluntary. In LOBBY it frees the seat. In PLAYING it does not: the seat remains and is played by the timer. Answered on the leaving socket by the same `player_left` (LOBBY) or `presence` (PLAYING) frame the rest of the room receives, with `re` set. The leaver is told what everyone else was told, not a snapshot of a room it is no longer in. |
| `ping` | `{ }` | Answered by `pong`. |

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
| `seat_assigned` | `{ "seat": 0..3, "seat_token": string }`. Sent once, to one client, immediately before its first `room`. |
| `player_joined` | `{ "seat": int, "name": string }` |
| `player_left` | `{ "seat": int }` |
| `presence` | `{ "seat": int, "connected": bool }` |
| `seat_seed` | `{ "seat": int, "client_seed": string, "origin": "player"\|"server" }`. Broadcast when a seat's seed is fixed. The seed is not a secret. Section 11. |
| `game_started` | `{ "turn": int, "game_id": string, "client_seeds": string }`. **No `seed_commit`** — the commitment is `chain_commit` and it was published at room creation. Section 11. |
| `rolled` | `{ "seat": int, "value": 1..6, "legal": [int], "deadline_ms": int, "k": int, "reveal": string }`. `legal` is the list of token indices this seat may move with this value. Empty means the turn is about to pass. `k` is the 1-based roll number within this game and `reveal` is `s[k]` as 64 lowercase hex characters; both ship in this same frame, never before it. Section 11. |
| `moved` | `{ "seat": int, "token": int, "from": int, "to": int, "captured": [{"seat":int,"token":int}], "extra_roll": bool }` |
| `turn_passed` | `{ "seat": int, "reason": "no_legal_move"\|"three_sixes" }` |
| `turn` | `{ "seat": int, "deadline_ms": int }` |
| `game_over` | `{ "winner": int, "verify_url": string }`. **No `seed`.** Nothing is withheld until the end any more: every roll's secret was already published in its own `rolled` frame, so a client can finish verifying before this frame arrives. `verify_url` is the permalink for later and for strangers. Section 11. |
| `error` | `{ "code": string, "message": string }`, with `re` set when it answers a specific message. |
| `pong` | `{ }` |

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
state a client renders — the UI has to show which seats contributed entropy and
which are trusting the server — so a client that missed one and does not know it
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
  "turn": { "seat": 1, "phase": "await_roll|await_move", "value": 6,
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
- `turn.k` is the roll number the **next** roll of this game will carry. It is
  `0` in LOBBY and equals the `k` of the last `rolled` frame once play has
  begun, so a client that reconnects mid-game knows where it is in the chain
  without replaying anything.
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
| `GAME_OVER` | any action against a FINISHED room. |
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
is wrong — not a string at all — is `BAD_FIELD` immediately, because no lookup
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

- `create_room`: 5 per hour per IP, and 3 per hour per device.
- `join_room` and `resume`: 20 per minute per IP. A wrong code counts. This is
  what makes the 32^6 code space unenumerable rather than merely large.
- any message: 30 per second, then `RATE_LIMITED`, then close at 60.

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
4. The server answers with the full `room` snapshot. The client discards its
   local state entirely and renders the snapshot. It does not attempt to
   reconcile, replay or animate the gap.
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

## 11. Verifiable dice — the 2026-08-28 amendment

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
| room is not in LOBBY | `WRONG_PHASE` |
| socket holds no seat | `BAD_SEAT_TOKEN` |
| `client_seed` absent, not a string, empty, over 64 characters, or containing anything outside `[A-Za-z0-9_-]` | `BAD_FIELD` |
| this seat already has a seed | `SEED_ALREADY_SET` |

`WRONG_PHASE` precedes the seat check here, unlike the five messages in section
7 whose identity check runs first, because a `set_seed` arriving after
`start_game` is a client racing the host rather than a client in no room, and
telling it "wrong phase" is the accurate answer. Say it, do not repair it.

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
dice. The engine already stopped drawing faces on run 11 — `RollIntention`
carries the face and the engine validates `1..6` — so the server is now the only
thing that decides a face, which is exactly where a verifiable scheme needs it.
