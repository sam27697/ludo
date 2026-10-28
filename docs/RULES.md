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
11a. A move that brings a token home (`progress = 57`) grants another roll,
    unless that move wins the game (rule 34). Sam's ruling of 2026-10-15. The
    engine toggle is `homeBonus`; it defaults off in the engine so that
    records written before the ruling replay unchanged, and the server turns
    it on for every room.
12. Extra rolls stack in the sense that they are a single boolean: after
    applying a move, the same seat rolls again if the roll was a 6, the move
    captured, or the move brought a token home, subject to rule 10. There is
    no queue of pending extra rolls.
13. Rule 7 applies to an extra roll exactly as it applies to a first roll: if
    the extra roll produces no legal move, the turn passes.

### 3.2a The roll queue (`rollQueue`), Sam's ruling of 2026-10-15

**Status: specified, not yet built.** Until the server orders land, live
rooms play rules 9 to 13 as written above.

Sam: «لازم اللاعب يرمي كل مرات النرد الممكنة قبل ما يلعب واذا اجاه فرصة رمي
جديدة اثناء التحريك وقتها بيرمي». Every roll a seat is owed is rolled first,
then the faces are spent. Engine toggle `rollQueue`, default off in the
engine (records from before the ruling replay unchanged), on for every
server room. With `rollQueue` on, rules 9, 12 and 13 are replaced by 9q to
13q; rules 7, 10 and 11, 11a keep their meaning as stated here.

9q. A turn holds a **queue** of unspent faces, in the order they were
    rolled. A turn begins with an empty queue and a roll.
10q. Rolling a 6 appends it to the queue and the same seat rolls again at
    once, before any move. Three consecutive 6s void the turn (rule 10):
    the third 6 is not queued, every unspent face is discarded, the turn
    passes; moves already made in the turn stand. `sixes` counts the
    current streak of consecutive 6s and resets to 0 on any non-6.
11q. A non-6 is appended and ends the rolling. The seat then spends the
    queue one face at a time, choosing which queued face and which token
    each time. A face may be spent on any token it moves legally; the
    order of spending is the player's choice.
12q. A move that captures (with `captureBonus`) or brings a token home
    (with `homeBonus`, not a winning move) owes one roll, rolled at once,
    before the next face is spent. That roll follows 10q and 11q: its
    faces join the end of the queue, a 6 rolls again, and three 6s in a
    row from it void the turn. A 6 spent on a move grants nothing; the 6
    was already rolled again when it landed.
13q. The turn passes when the queue is empty and no roll is owed, or when
    no queued face has any legal move (rule 7). A face with no legal move
    stays queued while another face can still move, because spending that
    other face may make it legal (a 6 brings a token out, then the 3 moves
    it). When the turn passes with faces left, they are discarded and the
    seat is told there was no move for them.
14q. Winning ends the game at once; unspent faces are discarded.
15q. Under the timer (rule 15), the server acts one step at a time exactly
    as a player would: roll if a roll is owed, otherwise spend the first
    queued face that has a legal move on its first legal token, in queue
    order then ascending token order.

### 3.3 The timer

14. A seat has 45 seconds from the moment the roll is delivered to it to select
    a token.
15. On expiry the server acts for the player: if exactly one legal move exists
    it plays that move; if several exist it plays the first in a deterministic
    ordering, defined as ascending token index; if none exist the turn has
    already passed under rule 7 and the timer was never armed.
16. A move played by the timer is a normal move in every other respect,
    including whether it grants an extra roll.

16a. The same 45 seconds bound the roll, not only the token selection. A
    seat that has not rolled when its segment expires is rolled for by the
    server, through the same dice chain and the same link ordering as a
    player-sent roll, and the roll's own consequences -- rule 7's pass, rule
    10's forfeit, a fresh segment for the selection it leaves pending --
    follow exactly as they would have. Items 14 to 16 alone left the table
    stalled for ever whenever a seat dropped before rolling rather than
    after, which is the state a disconnecting player is in most of the time,
    since a seat spends its whole idle life awaiting a roll.

16b. The timer is a property of the segment, not of the socket. A seat that
    is connected and simply not acting expires on the same schedule as one
    that has dropped.

16c. Added 2026-10-28, Sam's ruling. A seat whose player has been away
    for one whole turn of their own plays its later turns on **10 seconds**
    a segment instead of 45. "Away for one whole turn" means the seat was
    not connected when its turn began and did not reconnect at any point
    before that turn ended. From the end of such a turn the seat is
    **away**, and every segment that starts for it while it is away has a
    10 second budget; rules 15, 15q and 16a act on it exactly as they do
    on a 45 second one. The moment the seat reconnects it is no longer
    away, and if it is on turn with a 10 second segment running, that
    segment restarts at the full 45. Nobody is removed and no seat is
    given up: the seat, its tokens and its place in the turn order stay
    as they were. A seat that is connected and simply not acting is never
    away (rule 16b still holds for it), and a seat that drops in the middle
    of its turn, or between turns, still gets one whole turn at 45 seconds
    a segment before 16c applies.

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
    The engine toggle defaults on, but **since 2026-10-15 the server creates
    every room with `blocks` off** (Sam's ruling: a pair is safe from capture,
    never a wall). Rules 22 to 26 therefore describe the engine toggle and the
    records played before that date; a live game plays rule 28a.
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
    opponent token -- so a destination holding two or more tokens of one seat is
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

36. Given the same ordered list of intentions, the engine produces
    byte-identical state, on any machine, in any process, at any time. Every
    deviation from this is a defect, including one caused by iteration order
    over an unordered collection.

    This is stronger than the rule it replaces, which said "the same seed and
    the same intentions". The die face now travels inside the roll intention,
    so replay no longer depends on the engine's generator producing the same
    stream as the version that recorded the game.
37. The engine has no clock, no network, no file access and no global mutable
    state. The turn timer of rule 14 lives in the server, not the engine; the
    engine only ever sees the resulting move.
38. The engine draws no randomness at all. A roll intention carries the face it
    was drawn with; the engine checks it is an integer 1..6, rejects it
    otherwise, and applies the rules to it. Where the face came from is not the
    engine's business and cannot be, because `docs/FAIRNESS.md` requires a
    separate secret per roll and the engine is handed one game at a time.

    An engine that could draw a face could also produce one nobody can verify,
    which is why rule 37's ban on reaching a clock or a generator is what makes
    this rule enforceable rather than merely stated.

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
