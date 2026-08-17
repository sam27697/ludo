# Ludo

Online Ludo for Android. Private rooms, friends only.

One player creates a room and gets a short code and a link that mean the same
thing. Friends join by typing the code or by tapping the link. There is no
public matchmaking, no queue against strangers and no bots. Knowing the code is
the only way into a room.

The server is authoritative. It rolls the dice, it decides which moves are
legal, it owns the turn timer, and it holds the game state. The client sends an
intention and renders what comes back. That is what makes the game the same
game on four phones with four different clocks and four different connections,
and it turns a desync into a server bug that can be replayed instead of a
mystery.

A player who loses signal rejoins the same seat and finds the game where they
left it. Reconnection is a feature, not a recovery path.

English and Arabic, with mirrored right-to-left layout.

## Layout

Nothing is here yet beyond the scaffold. The tree fills in as the phases land.

    bin/ludo-verify.sh   one command, exit code is the verdict
    docs/                protocol spec, rules, decisions

## Verifying

    bin/ludo-verify.sh

Exit 0 means every gate that exists passed. The script prints which gates are
live and which are not yet implemented, so a green run never means more than it
should.

## Rules

The variant is pinned in `docs/RULES.md`. Ludo has a dozen regional variants
and an unpinned rule is a bug that surfaces in front of testers.
