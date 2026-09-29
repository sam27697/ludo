# The verification record and the page at `/v/<game_id>`

`docs/FAIRNESS.md` section 5 says what the page is for and section 7 lists it
as order 4. This file is the build spec for that order. Where it and
FAIRNESS.md disagree about the cryptography, FAIRNESS.md wins; where they
disagree about a field name, a route or a file, this file wins.

Until this exists, every finished game hands its players a `verify_url` that
answers 503.

## 1. What is stored, and when

One record per finished game, written at the moment the game is won, **before**
`move()` returns the result that carries `verify_url`. A client that taps
Verify the instant `game_over` arrives must find the record already there.

Only finished games get a record. A room reaped mid-game has no `verify_url`
and no record.

### 1.1 The record, format 1

A JSON object with exactly these keys:

| Key | Type | Value |
|---|---|---|
| `format` | int | `1` |
| `game_id` | string | `room.gameId`, 16 lowercase hex |
| `chain_commit` | string | `room.chain.commit`, 64 lowercase hex |
| `chain_index` | int | `room.chainIndex` |
| `chain_length` | int | `room.chain.chainLength` |
| `client_seeds` | string | `room.clientSeeds`, exactly the string the dice were drawn with |
| `seeds` | list | one object per seat in the game, ascending seat: `{"seat": int, "seed": string, "origin": "player" or "server"}` |
| `rolls` | list | one object per roll, ascending `k`, `k` = 1 .. `room.rollCount` with no gap: `{"k": int, "seat": int, "reveal": string, "die": int}` |
| `winner` | int | the seat of the engine's `GameWon` event |
| `finished_at` | string | the registry clock's `now` at the win, UTC, whole seconds, `YYYY-MM-DDTHH:MM:SSZ` |

`reveal` is `room.chain.reveal(k)`; `die` is the face that roll produced;
`seat` is the seat that rolled it, whether a player rolled or the turn timer
did. **A record never contains a reveal for any `k` above `room.rollCount`**,
and in particular never the chain root, unless the game really reached
`k == chain_length`. The unrevealed links are the secret for rolls that did
not happen; publishing them is harmless after the game but there is no reason
to, and a bug that published them early would look exactly like this.

**No display name, no seat token, no room code, no IP, anywhere in the
record.** Seat indices only (FAIRNESS.md section 5). The room code is left out
because codes are reissued after 24 hours and must not become a lookup key.

### 1.2 Where rolls come from

`Room` gains `final List<int> rollSeats = <int>[]`. `RoomRegistry.roll()`
appends the rolling seat on the one code path that sets `room.rollCount = k`,
in the same place, so `rollSeats.length == rollCount` always holds. Both the
client-driven and the timer-driven roll go through `roll()`, so there is no
second place to append.

## 2. The store

`packages/ludo_server/lib/src/verify_store.dart`:

```dart
const Duration verifyRetention = Duration(days: 90);
const String defaultVerifyUrlBase = 'https://provefair.app/v/';

/// A game id this server could have issued: exactly 16 lowercase hex.
bool isWellFormedGameId(String s);

abstract class VerifyStore {
  /// Stores [json] under [gameId]. Returns false and changes nothing if a
  /// record for [gameId] already exists. Throws on an I/O failure.
  bool save(String gameId, String json);

  /// The exact string [save] was given, or null. Null, never a throw, for an
  /// id that fails [isWellFormedGameId].
  String? load(String gameId);

  /// Deletes every record saved before [cutoff]; returns how many.
  int purgeOlderThan(DateTime cutoff);
}

class MemoryVerifyStore implements VerifyStore {
  MemoryVerifyStore(Clock clock); // save time is clock.now
}

class DirectoryVerifyStore implements VerifyStore {
  DirectoryVerifyStore(String path); // creates the directory if missing
}
```

`DirectoryVerifyStore` writes `<path>/<game_id>.json` by writing
`<game_id>.json.tmp` in the same directory and renaming it over, so a reader
never sees half a file. The save time is the file's modification time.
`load` and `save` refuse an id that fails `isWellFormedGameId` before building
any path from it (no traversal, whatever the id). Files that do not match
`<16 hex>.json` are ignored by `purgeOlderThan`, never deleted.

## 3. The registry

```dart
RoomRegistry({
  required Clock clock,
  required Random secure,
  VerifyStore? verifyStore,              // default MemoryVerifyStore(clock)
  String verifyUrlBase = defaultVerifyUrlBase,
});

VerifyStore get verifyStore;
```

- `verify_url` becomes `'$verifyUrlBase${room.gameId}'`.
- On a win, the registry builds the record (`buildVerifyRecord` in
  `packages/ludo_server/lib/src/verify_record.dart`,
  `Map<String, Object?> buildVerifyRecord(Room room, {required int winner, required DateTime finishedAt})`),
  `jsonEncode`s it and calls `verifyStore.save`. If `save` throws or returns
  false, the game still ends normally and `move()` still returns its
  `MoveOk`: a player must never lose a finished game to a full disk. The
  failure is written to stderr as one line,
  `verify_record_not_saved game_id=<id> reason=<exception text or "exists">`.
  It is not swallowed silently.
- `reap()` also calls `verifyStore.purgeOlderThan(now - verifyRetention)`.

## 4. The routes

Answered before the WebSocket upgrade, like `/health`, `/privacy` and `/r/`.
`GET` and `HEAD` only (`HEAD` = same status and headers, empty body); any other
method is `405` with `allow: GET, HEAD`.

| Path | Found | Not found / malformed |
|---|---|---|
| `/v/<id>` | `200`, `text/html; charset=utf-8`, the page | `404`, `text/html; charset=utf-8`, a short page: no record for this id, records are kept for 90 days |
| `/v/<id>.json` | `200`, `application/json`, **byte-for-byte the stored string** | `404`, `application/json`, `{"error":"not_found"}` |
| `/v/verify.js` | `200`, `text/javascript; charset=utf-8` | |
| `/v/verify.py` | `200`, `text/x-python; charset=utf-8` | |

`<id>` must pass `isWellFormedGameId`; anything else under `/v/`, including
upper-case hex, a trailing slash, an encoded slash or `..`, is the not-found
answer of the row it most resembles, and never touches the store.

Headers on every `/v/` response: `x-content-type-options: nosniff`,
`referrer-policy: no-referrer`. On the HTML page, also
`content-security-policy: default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`.
On the `.json` answer, also `access-control-allow-origin: *`, so anybody's own
tool can fetch a record. Found records and the two scripts:
`cache-control: public, max-age=300`. Not-found answers: `cache-control: no-store`.

## 5. The page

Server-rendered HTML, readable with JavaScript off, English. Everything taken
from the record is HTML-escaped. It shows, in this order:

1. The game id, the finish time (UTC) and the winning seat, as "Seat N".
2. What the checks prove and what they do not, in two short lists, from
   FAIRNESS.md section 0: the server fixed every roll before the game and
   could not change them; the players' seeds were mixed into every roll after
   that commitment; no roll's secret was published before the roll. **Not**
   proven: that the server's secret itself came from a good random source.
   The words "provably fair", "absolutely random", "odds", "bet" and "wager"
   do not appear.
3. `chain_commit`, `chain_length`, and the seeds table: seat, seed, and origin
   in words ("chosen by this player" / "drawn by the server: this seat added
   no randomness of its own").
4. The rolls table: `k`, seat, die, reveal, and two check cells per row,
   "chain" and "die", which read "not checked" in the HTML and are filled in
   by `verify.js`.
5. A summary line with id `summary`, "not checked" in the HTML.
6. How to check it without trusting this page: the command
   `curl -sO https://provefair.app/v/verify.py && python3 verify.py <game_id>`
   and the link to the source, `https://github.com/sam27697/ludo`.
7. "This record is kept for 90 days after the game ends."

The record itself is embedded as
`<script type="application/json" id="record">` holding the stored JSON with
every `<` character replaced by the six-character JSON escape (a backslash, then `u003c`), so a seed can never close the element. In Dart source, write that replacement so the six characters are not contiguous in the file, for example `r'\u' '003c'`, because at least one editing tool on this box turns the contiguous form into a literal `<`.
`<script src="/v/verify.js"></script>` loads the checker. No other script, no
external resource, no font, no image.

## 6. `verify.js`

Plain JavaScript, no dependencies, WebCrypto (`crypto.subtle`) for SHA-256 and
HMAC-SHA256, readable top to bottom. Two exported functions, and the file must
also run under Node 20+ with `require`:

```js
// face for roll k, die index d, exactly FAIRNESS.md section 2.3
async function drawDie(revealHex, gameId, clientSeeds, k, d) -> number

// every check of section 7 below
async function verifyRecord(record) -> {
  ok: boolean,
  error: string | null,            // first record-level failure, or null
  rolls: [{ k, chainOk, dieOk, computedDie }]
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = { drawDie, verifyRecord };
} else {
  // read #record, run verifyRecord, fill the check cells and #summary
}
```

## 7. `verify.py`

Python 3, standard library only (`hashlib`, `hmac`, `json`, `sys`,
`urllib.request`), readable top to bottom.

    python3 verify.py <game_id | https URL of a .json record | path to a .json file>

A bare 16-hex argument fetches `https://provefair.app/v/<game_id>.json`. It
prints one line per roll and then either `PASS: <n> rolls verified against
chain_commit <commit>` and exits 0, or `FAIL: <what>` and exits 1. Importable:
`draw_die(reveal_hex, game_id, client_seeds, k, d) -> int` and
`verify_record(record) -> (ok: bool, lines: list[str])`.

Both checkers apply exactly these checks, and any one failing fails the record:

1. `format == 1`.
2. `client_seeds` equals the `seeds` list joined as `seat:seed` with `|`.
3. `rolls[i].k == i + 1` for every `i` (starts at 1, no gap, no repeat).
4. Chain: `sha256(bytes(reveal_k)) == previous`, where previous is
   `chain_commit` for `k = 1` and `reveal_(k-1)` after that.
5. Die: `draw_die(reveal_k, game_id, client_seeds, k, 0) == die`.

## 8. Configuration and deployment

| Variable | Meaning | Unset |
|---|---|---|
| `LUDO_VERIFY_DIR` | directory for `DirectoryVerifyStore` | `MemoryVerifyStore`, and startup prints `verify store: memory, records are lost on restart` |
| `LUDO_VERIFY_BASE_URL` | the `verify_url` prefix, must start with `https://` or `http://` and end with `/` | `defaultVerifyUrlBase`; a malformed value is a startup failure, exit non-zero |

- The image creates `/data/verify` owned by `10001:10001`. Compose mounts a
  named volume per environment there and sets `LUDO_VERIFY_DIR=/data/verify`.
- Staging `.env`: `LUDO_VERIFY_BASE_URL=https://stg.ludo.provefair.app/v/`.
  Production: unset (the default, `https://provefair.app/v/`).
- `provefair.app` is proxied to `127.0.0.1:8080`, which nothing uses. The
  **production** container publishes `127.0.0.1:8080` in addition to 8099, from
  a production-only compose override, so `provefair.app/v/<id>` is answered by
  the process that holds the records. Staging never publishes 8080.
- `provefair.app` is not, and must never become, an App Link host.

What would tell us it broke: a finished game whose `verify_url` does not answer
200 from outside, or `verify.py` failing against a real record.

## 9. Not in this order

A landing page at `provefair.app/`; an Arabic page; records for games
abandoned mid-play; the client showing anything new. Each is its own order.
