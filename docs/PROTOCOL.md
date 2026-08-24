# Protocol

Frozen 2026-08-18. This is master-written and it is not a work order's to
change. An implementation that cannot satisfy this file reports that; it does
not adjust the file.

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
  `ABCDEFGHJKLMNPQRSTUVWXYZ23456789` — 32 symbols, no `0`/`O`, no `1`/`I`/`L`.
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
  count. Only the host may start it, and only when at least 2 seats are filled.
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
| `start_game` | `{ }` | Host only. LOBBY only. At least 2 seats filled. |
| `roll` | `{ }` | Only the seat whose turn it is, only when the turn is awaiting a roll. |
| `move` | `{ "token": 0..3 }` | Only the seat whose turn it is, only when a roll is pending a selection. |
| `leave_room` | `{ }` | Voluntary. In LOBBY it frees the seat. In PLAYING it does not: the seat remains and is played by the timer. |
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
| `game_started` | `{ "turn": int, "seed_commit": string }` |
| `rolled` | `{ "seat": int, "value": 1..6, "legal": [int], "deadline_ms": int }`. `legal` is the list of token indices this seat may move with this value. Empty means the turn is about to pass. |
| `moved` | `{ "seat": int, "token": int, "from": int, "to": int, "captured": [{"seat":int,"token":int}], "extra_roll": bool }` |
| `turn_passed` | `{ "seat": int, "reason": "no_legal_move"\|"three_sixes" }` |
| `turn` | `{ "seat": int, "deadline_ms": int }` |
| `game_over` | `{ "winner": int }` |
| `error` | `{ "code": string, "message": string }`, with `re` set when it answers a specific message. |
| `pong` | `{ }` |

`deadline_ms` is milliseconds remaining, not an absolute timestamp. Four phones
do not agree on the wall clock and the client must not be asked to reconcile
them.

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
  "seats": [
    { "seat": 0, "name": "Sam", "connected": true, "tokens": [-1, 0, 14, 57] }
  ],
  "turn": { "seat": 1, "phase": "await_roll|await_move", "value": 6,
            "legal": [0, 2], "deadline_ms": 41200, "sixes": 1 },
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
- `seed_commit` in `game_started` is a hash of the game seed, published before
  play. The seed itself is published in `game_over`. This costs nothing and it
  means a player who suspects the dice can check afterwards that they were
  fixed before the game started rather than chosen during it.

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
| `NOT_ENOUGH_PLAYERS` | `start_game` with fewer than 2 seats filled. |
| `NOT_YOUR_TURN` | an action from a seat that is not on turn. |
| `WRONG_PHASE` | `roll` when a move is pending, or `move` when a roll is pending. |
| `ILLEGAL_MOVE` | the token is not in the `legal` list for the current roll. |
| `BAD_SEAT_TOKEN` | `resume` with a token that matches no seat in that room. |
| `GAME_OVER` | any action against a FINISHED room. |
| `INTERNAL` | a bug. Logged with the room code and the sequence number. |

Every inbound message is validated in this order and rejected at the first
failure, before any state is touched: size, JSON parse, `v`, `t`, `id` shape,
rate limit, room exists, seat authorised, phase correct, payload fields, rule
legality. Reject, never repair.

Rate limits, per connection unless stated:

- `create_room`: 5 per hour per IP, and 3 per hour per device.
- `join_room` and `resume`: 20 per minute per IP. A wrong code counts. This is
  what makes the 32^6 code space unenumerable rather than merely large.
- any message: 30 per second, then `RATE_LIMITED`, then close at 60.

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
