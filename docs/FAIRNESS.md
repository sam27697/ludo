# Verifiable dice

Sam, 2026-08-26: *"basic concept of the game is the absolute random dice roll
which can be verified for each dice roll so any player must be able to verify
by a link each dice roll made in his game to assure absolute randomness .. same
for new games to be developed (backgammon next)"*

This is not a feature of the Ludo game. It is the product, and every game after
it inherits it. This document is therefore game-agnostic on purpose: it never
mentions Ludo, it produces die faces, and Backgammon consumes it unchanged by
asking for two faces per roll instead of one.

## 0. What is proven, and what is not

Say this precisely, in the app and in the store listing, because the honest
claim is narrower than "absolute randomness" and a technical player will check.

**Proven, by anyone, without trusting the server:**

- The server fixed every future roll *before* the game began, and could not
  change any of them afterwards.
- The server could not have chosen the outcomes it wanted, because the players'
  own input is mixed into every roll and the server committed before it saw it.
- No player could predict a roll before it happened, and no player could
  influence it, because the server's secret for that roll was not published
  until after the roll was shown.
- Roll number 7 of a specific game produced a specific face, recomputable by
  hand from published values.

**NOT proven, and it must not be claimed:**

- That the server's secret came from a good entropy source. A server drawing
  its secret from a broken generator passes every check in this document. The
  only fixes are a third-party randomness beacon or an audited build, and
  neither is in scope now. Section 8 keeps the door open.
- "Absolute randomness" as a phrase. Nothing can prove that. **Say "every roll
  is verifiable" and never "absolutely random".**

**Store-listing warning.** "Provably fair" is crypto-casino vocabulary. The
mechanism is right; the words carry a real Google Play risk under the
real-money-gambling policy. Describe the app as *verifiable randomness* and
never in language about odds, fairness of stakes, or wagering.

## 1. Why the current design cannot do this

As built today: one 64-bit seed per game from the server CSPRNG,
`seed_commit = sha256(seed.toString())` in `game_started`, the seed revealed in
`game_over`, and the engine draws every face from SplitMix64 over that seed.

That is a real commitment and it was worth building. It is also not what he
asked for, in four specific ways:

1. **It is per-game, not per-roll, and only after the game.** One seed cannot
   be revealed mid-game without revealing every future roll at once.
2. **The server can grind.** It chooses the seed alone and commits to a seed it
   already picked freely, so nothing stops it generating candidate seeds until
   one produces a sequence it likes. The commitment proves the server did not
   change its mind. It does not prove the server did not choose the outcome.
   **Players contribute zero entropy.** This is the important gap.
3. **64 bits is too small for a commitment** whose preimage space is exactly
   the 64-bit integers written in decimal.
4. **There is no link.** Nothing is stored -- rooms are reaped after 60 minutes
   -- so a player cannot check anything tomorrow.

## 2. The scheme

A backward hash chain for the per-roll secrets, with player entropy mixed into
every draw. The chain gives live per-roll reveal; the player entropy kills
grinding. Neither alone is enough.

### 2.1 The chain

    N = 4096
    s[N] = 32 bytes from the server CSPRNG          (the server secret)
    s[k-1] = SHA-256(s[k])                          for k = N .. 1
    chain_commit = lowercase hex of s[0]

`chain_commit` is published when the **room is created**, in the first `room`
frame, before any player has submitted anything.

Roll number `k` (1-based, per game) uses `s[k]`, published immediately after
that roll's result is shown. A player verifies a reveal by hashing it once:
`SHA-256(s[k]) == s[k-1]`, chaining back to the `chain_commit` they were given
at the start. **Preimage resistance is what makes this safe to reveal live:**
`s[k]` tells nobody anything about `s[k+1]`.

If a game somehow exceeds N rolls the server starts a second chain and
publishes a new `chain_commit` with a `chain_index`. Rolls carry their
`chain_index`. This never happens in practice -- the 40-game golden corpus tops
out at 945 intentions -- but a silent wrap would be a forged roll, so it is
explicit.

### 2.2 Player entropy

The chain alone is grindable: the server builds the whole chain before
publishing `s[0]`, so it could search chains for one it likes. Player seeds
close that, because they arrive **after** the commitment is public.

- Any seated player MAY send `set_seed` once, in LOBBY only, after receiving
  the `room` frame that carries `chain_commit`. 1 to 64 characters of
  `[A-Za-z0-9_-]`.
- A seat that sends none is given a server-generated 16-byte hex seed, recorded
  with `origin: "server"`. **The UI must show that seat as not having
  contributed entropy.** It is still auditable; it is simply a seat that chose
  to trust the server.
- At `game_started` the server freezes and publishes the combined string:
  seats in ascending index, `seat:seed`, joined by `|`. For example
  `0:alice-seed|2:bob-seed`.

The ordering is the whole security argument and must be provable from the
transcript, not promised: **commitment first, player seeds second, play third.**

### 2.3 One die face

For roll `k`, die index `d` (`0` for a single die; `0` and `1` for backgammon):

    msg    = "<game_id>|<client_seeds>|<k>|<d>"
    digest = HMAC-SHA256(key = s[k], message = UTF-8 bytes of msg)

Read `digest` as eight big-endian 32-bit words. Take the first word `u` with
`u < 4294967292`; the face is `(u mod 6) + 1`.

`4294967292 = 2^32 - (2^32 mod 6)`, so the accepted range is exactly
`6 x 715827882` values and there is **no modulo bias**. Rejection is
astronomically rare (4 in 2^32 per word); if all eight words are rejected,
re-HMAC with `msg + "|r1"`, then `|r2`, and so on.

`game_id` is a server-generated 16-hex-character identifier published in
`game_started`. It is the key of the verification permalink and it is not the
room code, because room codes are reissued after 24 hours.

### 2.4 Test vectors -- the implementation is checked against these

`packages/fair_dice/test/vectors.json`, generated 2026-08-26 and **verified by
two independent implementations, one in Dart and one in Python, written from
this document and agreeing byte for byte.** An implementation that does not
reproduce these exactly is wrong, whatever its own tests say.

With `server_secret =`
`00112233445566778899aabbccddeeff102132435465768798a9bacbdcedfe0f`,
`N = 4096`, `game_id = 7f3a9c1e5b2d4068`,
`client_seeds = 0:alice-seed|2:bob-seed`:

    chain_commit = 4b871c475275752379eceb6bcb00f855d4dbc4231e43081924f7ea52135efcbe

    k=1     s[1] = 5187a31a21e561dd91798c4641381afab4e229b6b28b9ed040d2ef61d4c8eac0   die 6
    k=2     s[2] = 2181ae443ee0898c4237cfde714858b2d0c78f58d5c1be605572616fc63b43d1   die 1
    k=3     s[3] = c1fbe6f7d1157e18e9f06ab5cac22a1c6d5a63551370e9be3b3553776812073f   die 1
    k=17    s[17]= 1e151f8499b23d7eec1c257019188c9c3cba8f75a281d1610db6bbc594ed4f31   die 4
    k=100   s[100]=77f8a0aecad0d2c5f392632df31830d5f6433eafe4790219380519f082ae0cff   die 4
    k=4096  s[4096] = the server secret itself                                        die 5

    backgammon, two dice off one reveal:
    k=1 -> [6, 1]     k=2 -> [1, 4]     k=7 -> [2, 4]

Uniformity, measured not assumed: 20 independent trials, 122,880 draws each,
2.4 million draws total. Chi-square with 5 degrees of freedom came out mean
**4.25** against an expected 5.0, median 3.01, maximum 14.82, with **1 of 20**
trials above the p<0.05 threshold of 11.07 where about 1 is expected, and
**0 of 20** above the p<0.001 threshold. A single earlier 61,440-draw sample
read 21.9 and was noise; one sample is not a distribution test, and the spec
requires the multi-trial form.

## 3. What this forces to change, and it is not small

**The engine must stop generating randomness.** Rule 38 today says all
randomness comes from the seeded generator the engine is given. That is
incompatible with per-roll verification, because per-roll verification needs a
per-roll secret and the engine holds one seed for the whole game. There is no
way around this.

The change: **`RollIntention` carries the drawn face.** The engine validates it
is 1..6 and applies the rules. It never draws. `rng.dart` stays for the corpus
generator and offline simulation and is no longer on the gameplay path.

Consequences, all of them intended:

- **Rule 36 gets stronger, not weaker.** "Same seed and same intentions" becomes
  "same intentions", because the faces are in the intention stream. Determinism
  no longer depends on the engine's generator matching across versions.
- **The golden corpus regenerates.** `STATE.md` says a hash change in the golden
  corpus is a defect until proven an intended rule change. **This is that
  intended rule change**, and the order making it must say so in the commit
  message and prove the new corpus replays.
- **The engine becomes a pure rules referee.** For backgammon that is also the
  right shape.
- **The purity gate still holds** and matters more: an engine that cannot reach
  a clock or a generator cannot smuggle in an unverifiable face.

**This is why order 008 must not be dispatched as written.** It owns `roll`,
and shipping it against the one-seed contract means writing the turn loop twice.

## 4. Protocol changes

Replacing `seed_commit` and `game_over.seed`:

| Frame | Change |
|---|---|
| `room` | gains `chain_commit` and `chain_index`, published at room creation |
| `set_seed` (new, client to server) | `{ "client_seed": string }`. LOBBY only, once per seat, after the seat has a `room` frame. Answered by `seed_set`. |
| `seed_set` (new) | `{ "seat": int, "origin": "player"\|"server", "seq": int }`. The seed value itself is broadcast, since it is not a secret. |
| `game_started` | gains `game_id` and `client_seeds`; keeps `chain_commit`; **drops `seed_commit`** |
| `roll` | gains `k`, `reveal` (`s[k]`, hex) and `die`. The reveal ships in the same frame as the result, never before. |
| `game_over` | **drops `seed`**; gains `verify_url` |

The reveal is in the roll frame itself, so an offline client can verify without
any network call. The link is for a stranger, for later, and for the sceptic
who does not trust the app either.

## 5. The verification link

`https://provefair.app/v/<game_id>` -- a plain web page, in the browser, for
somebody who trusts nothing here.

- Shows: `chain_commit`, every seat's client seed and its origin, and every
  roll as `k`, reveal, die, and the two checks
  (`SHA-256(reveal) == previous`, `HMAC -> die`).
- Ships the verifier as readable client-side JavaScript **and** as a copyable
  command, so the page can be checked without running the page's own code.
  A page that only verifies itself proves nothing.
- **Must not be an Android App Link host.** If the app intercepted its own
  audit page, the app would be grading its own homework, and a sceptic without
  the app would be bounced to a store listing instead of the maths.
- **Seat indices only. No display names, ever.** Keeps the page free of
  personal data and keeps the Play Data safety declaration clean.

**This introduces persistence, which the server deliberately does not have
today.** Rooms are in memory and reaped after 60 minutes. A verification link
that dies with the room is not a verification link. That is a new component and
its own work order: a small store holding, per game, the commitment, the seeds,
the per-roll reveals and faces. Nothing else. Retention should be stated
publicly and honoured.

## 6. Shared package

`packages/fair_dice` -- chain construction, reveal verification, the HMAC draw,
and the vectors. Pure Dart, no I/O, no clock, under the same purity gate as the
engine. Ludo depends on it. Backgammon depends on it unchanged. The browser
verifier is a direct port of the same twenty lines.

## 7. Orders this generates

1. `packages/fair_dice` plus the vectors above, and a harness gate that fails
   if any vector does not reproduce.
2. The engine change of section 3: `RollIntention` carries the face, rule 38
   rewritten, golden corpus regenerated and proven to replay.
3. Protocol section 4, then **order 008 rewritten** on top of it.
4. The verification store and the public page.

Order 1 is independent of everything and can start immediately. Order 2 blocks
order 3, which blocks the rewritten 008.

## 8. Left open, deliberately

A public randomness beacon such as drand would let the server bind its
commitment to a value published later by an independent network, which is the
only thing that would close the entropy-source gap in section 0. It costs a
network dependency at game start. Not now; not forgotten.
