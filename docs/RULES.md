# Rules

Frozen 2026-08-18. Ludo has a dozen regional variants and an unpinned rule is a
bug that surfaces in front of testers. Everything here is exact on purpose:
every numbered line below is an acceptance test before it is a line of code.

Nothing in this file may be changed by an implementation work order. If an
implementation cannot satisfy a line here, it reports that; it does not adjust
the line. Changing a rule is its own order and it invalidates the golden corpus.

## 1. The board

### 1.1 Geometry

The main track is 52 squares, indexed 0 to 51, shared by every player, and it
wraps: the square after 51 is 0.

Each seat has a fixed entry offset onto the main track:

| Seat | Colour | Entry square |
|---|---|---|
| 0 | red | 0 |
| 1 | green | 13 |
| 2 | yellow | 26 |
| 3 | blue | 39 |

Colour is presentation only. Nothing in the engine may branch on colour; it
branches on seat index.

### 1.2 A token's position

A token has one integer, `progress`, and that integer is the whole of its
position. There is no second coordinate.

| `progress` | Meaning |
|---|---|
| `-1` | in the yard, not yet in play |
| `0` to `51` | on the main track, at absolute square `(entry + progress) mod 52` |
| `52` to `56` | in the seat's home column, cells 1 to 5 |
| `57` | home, finished, immovable forever |

So `progress = 0` is the seat's own entry square, `progress = 51` is the square
one before it going backwards around the loop, and a token needs exactly 57
steps from entry square to home.

The home column is private. Cells 52 to 56 of one seat share no square with any
other seat and can never be occupied or captured by another seat's token. Only
main track positions, 0 to 51, are shared.

### 1.3 Safe squares

Eight squares on the main track are safe, absolute indices:

    0, 8, 13, 21, 26, 34, 39, 47

That is the four entry squares plus the square eight ahead of each. These are
the starred squares on the printed board.

A token standing on a safe square cannot be captured. Every home column cell is
also safe, trivially, because no opponent can reach it.

## 2. Setup

1. A game has 2, 3 or 4 players. Each has exactly 4 tokens.
2. Seats are assigned by join order. Two players take seats 0 and 2, so they
   sit opposite. Three players take seats 0, 1 and 2. Four players take 0, 1, 2
   and 3.
2a. The seat set is fixed by the number of players **actually in the game**, not
   by whatever count the room was created with. A game of two is always seated 0
   and 2, never 0 and 1, however the room got down to two. A server that starts
   a game on a partly filled room breaks this rule, so a game may only start
   from a full room.
3. Every token starts at `progress = -1`.
4. Turn order is ascending seat index, wrapping to the lowest occupied seat.
   The host's seat moves first.

## 3. The turn

### 3.1 Rolling

5. A turn begins with exactly one die roll, a uniform integer 1 to 6 inclusive.
   The server rolls it from a cryptographic generator. A client that sends a
   die value is committing a protocol error, not making a move.
6. After the roll, the engine computes the set of legal moves for the rolling
   seat given that value.
7. If that set is empty, the turn passes to the next seat automatically and
   immediately. This is not an error and it does not consume a timer expiry.
8. If that set is non-empty, the player selects one token to move. Selecting a
   token that has no legal move for this roll is rejected and the turn does not
   change hands.

### 3.2 Extra rolls

9. Rolling a 6 grants the player another roll after the resulting move is
   applied.
10. Three consecutive 6s in one turn forfeit the turn. The third 6 is not
    played at all: the move it would have allowed is not made, and the turn
    passes immediately. Any moves made on the first and second 6 stand.
11. A capture grants another roll after the capturing move is applied. This is
    on by default.
12. Extra rolls stack in the sense that they are a single boolean: after
    applying a move, the same seat rolls again if the roll was a 6 or the move
    captured, subject to rule 10. There is no queue of pending extra rolls.
13. Rule 7 applies to an extra roll exactly as it applies to a first roll: if
    the extra roll produces no legal move, the turn passes.

### 3.3 The timer

14. A seat has 45 seconds from the moment the roll is delivered to it to select
    a token.
15. On expiry the server acts for the player: if exactly one legal move exists
    it plays that move; if several exist it plays the first in a deterministic
    ordering, defined as ascending token index; if none exist the turn has
    already passed under rule 7 and the timer was never armed.
16. A move played by the timer is a normal move in every other respect,
    including whether it grants an extra roll.

## 4. Movement

17. A token in the yard, `progress = -1`, may leave only on a roll of 6, and it
    moves to `progress = 0`, its entry square. It does not additionally advance
    by 6.
18. A token on the track or in the home column advances by exactly the rolled
    value: `progress` becomes `progress + roll`.
19. Entering home requires an exact roll. A move whose result would exceed
    `progress = 57` is illegal and that token is not selectable for that roll.
    There is no bounce-back.
20. A token at `progress = 57` is home. It is never movable again and it is
    never capturable.

### 4.1 Blocks

21. Two or more tokens of the same seat on one main track square form a block.
    This is on by default.
22. A block cannot be passed or landed on by any token of another seat. A move
    whose path crosses a square holding an opponent's block is illegal.
23. "Path" means every square strictly between the origin and the destination,
    plus the destination. A token leaving the yard under rule 17 has a path of
    exactly its entry square.
24. A block does not obstruct its own owner. A seat's tokens pass and stack on
    their own block freely.
25. A block is only meaningful on the main track. Home column cells cannot be
    blocked against anyone, because no opponent can enter them.
26. A block on a safe square is both a block and safe. The two rules do not
    interact.

### 4.2 Capture

27. A move that ends on a main track square holding exactly one token of a
    different seat sends that token home: its `progress` returns to `-1`.
28. Capture requires exactly one opponent token on the destination. Two or more
    is a block and the move was already illegal under rule 22.
28a. That reasoning holds only while `blocks` is on. With `blocks` off, rule 22
    never fires, the move is legal, and rule 28 still requires exactly one
    opponent token — so a destination holding two or more tokens of one seat is
    landed on and **nothing is captured**. Turning blocks off therefore does not
    make stacking worthless: it converts a hard block into a shelter that cannot
    be captured, and the arriving token stands on the square alongside them.
    This is deliberate. Rule 27 counts tokens, and it counts them the same way
    whatever the toggles say; the alternative is a `blocks` toggle that silently
    changes what capture means, which is worse. Say it in the UI rather than
    special-casing it in the engine.
29. A capture cannot happen on a safe square. A move that would end on a safe
    square holding one opponent token is legal, and both tokens then stand on
    that square together, neither captured. This is the single most commonly
    mis-implemented rule in the set.
30. A token can never capture its own seat's token. Landing on a square holding
    one of your own tokens is legal and forms a block.
31. Capture is decided only by the destination square. Tokens passed over are
    never captured.
32. A capture grants another roll, per rule 11.

## 5. Ending

33. The first seat to bring all 4 tokens to `progress = 57` wins.
34. The game ends the moment that happens. Remaining places are not played out
    and there is no second or third place.
35. A game state where a winner exists is terminal. No further roll, move or
    timer is accepted against it.

## 6. Determinism

36. Given the same seed and the same ordered list of intentions, the engine
    produces byte-identical state, on any machine, in any process, at any time.
    Every deviation from this is a defect, including one caused by iteration
    order over an unordered collection.
37. The engine has no clock, no network, no file access and no global mutable
    state. The turn timer of rule 14 lives in the server, not the engine; the
    engine only ever sees the resulting move.
38. All randomness comes from the seeded generator the engine is given. The
    server supplies a cryptographically generated seed per game; the engine
    itself is a pure function of seed and intentions.

## 7. The cases that must be tested explicitly

These are the ones a naive implementation gets wrong. Each is its own test.

1. Landing on a safe square occupied by one opponent token captures nothing and
   leaves both tokens standing (rule 29).
2. A move whose path crosses an opponent block is rejected, and the same move
   is accepted after the block is reduced to one token (rules 22, 23).
3. A move that lands exactly on an opponent block is rejected, not treated as a
   capture (rule 28).
4. Three consecutive 6s forfeit the turn and the third 6's move is not applied
   (rule 10).
5. Overshooting home is illegal: a token at `progress = 55` rolling 4 has no
   legal move for that token (rule 19).
6. A roll producing no legal move for any token passes the turn immediately,
   with no timer and no error (rule 7).
7. A 6 rolled when every token is already out of the yard still grants an extra
   roll and does not force a yard exit (rules 9, 17).
8. A seat's own tokens stacking is legal and forms a block, and the seat's
   other tokens still pass it (rules 24, 30).
9. Two tokens reaching home on consecutive rolls of one turn, the second one
   winning the game, terminates the game at the correct moment (rules 33, 35).
10. A capture on the last legal move grants an extra roll even though the
    capture also emptied the board of that seat's reachable targets (rule 11).
11. A token leaving the yard onto its entry square that holds one opponent
    token: the entry square is safe by rule 1.3, so nothing is captured.
12. Passing over an opponent's single token does not capture it (rule 31).

## 8. What is deliberately not in this version

No public matchmaking, no queue, no bots, no strangers. The brief is friends
only and the room code is the only way in. Do not add them.

No second and third place, no scoring, no ranking, no persistence of results
between games.
