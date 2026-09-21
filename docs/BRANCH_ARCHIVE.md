# Branch archive, 2026-09-21

On 2026-09-21 this repository carried 122 branches besides `main`. They were
the working surface of two build systems that ran side by side: the work-order
runs, which name their branches `order/*`, `work/*`, `wt/*` and `integrate/*`,
and the UX program, which names its branches `ux/*`. Both merge through
squashed pull requests, and neither deletes the branch afterwards, so the list
grew by roughly one branch per order and never shrank.

Counted against `main` as it stood that morning: 94 were already in it, 17 were
the pre-squash originals of pull requests that had already landed, 6 were UX
program spikes, which `uxprogram-kit/kit/PROGRAM.md` says are never merged, and
5 carried something `main` had never seen. Four of those five were merged that
day: the three `ux/*` branches, which are one lineage, and the cloud agent
environment from pull request 38. The fifth was wire-smoke diagnostics for a
reconnect stall that the resume watchdog had already closed, and it was left
where it was. Every other branch was deleted.

Nothing was thrown away. Every tip listed below is a parent of one commit,
`archive/workshop-2026-09-21`, which carries no change of its own: its tree is
main's and its only job is to keep those commits reachable once the branches
are gone.

An anchor like this belongs on a tag rather than a branch, and moving it is one
command from a checkout that can write tags:

    git tag -a workshop-archive-2026-09-21 origin/archive/workshop-2026-09-21 \
        -m "Every branch besides main as of 2026-09-21, kept reachable"
    git push origin workshop-archive-2026-09-21
    git push origin :archive/workshop-2026-09-21
    # then point ARCHIVE_REF in tool/prune_branches.sh at the tag

`tool/prune_branches.sh` is what clears the branch list. It refuses to delete a
branch whose tip is reachable from neither the anchor nor `main`, so it cannot
be the thing that loses work, and it prints the plan unless given `--yes`.

To bring a branch back:

    git fetch origin
    git branch <name> <commit>       # the commit column below
    # or read one file out of it without a checkout:
    git show <commit>:<path>

The dates are each branch's last commit, not the date it was archived.

| branch | commit | last commit | disposition |
|---|---|---|---|
| `client/board-geometry` | `5337a45` | 2026-08-28 | already in main |
| `client/board-tests` | `a7e2ca4` | 2026-08-28 | already in main |
| `client/board-widget` | `abd3c29` | 2026-08-28 | already in main |
| `client/release-signing` | `b3789a1` | 2026-08-28 | already in main |
| `client/room-connection` | `ad81e6f` | 2026-08-29 | already in main |
| `client/screenshot-lag` | `1bdf8d3` | 2026-08-28 | already in main |
| `client/shell` | `e134841` | 2026-08-28 | already in main |
| `client/wire-codec` | `183672c` | 2026-08-29 | already in main |
| `client/wire-codec-tests` | `97a7346` | 2026-08-29 | already in main |
| `client/ws-transport` | `f9116c5` | 2026-08-29 | already in main |
| `cursor/home-ui-felt-die-9a17` | `c5e5f74` | 2026-09-10 | already in main |
| `cursor/setup-cloud-agent-environment-edc6` | `7f1906d` | 2026-09-10 | merged into main on 2026-09-21, pull request 38 |
| `fix/static-gate-format` | `4c661e8` | 2026-09-05 | already in main |
| `integrate/board` | `aa73c57` | 2026-08-28 | already in main |
| `integrate/client-codec` | `3bcb8a4` | 2026-08-29 | already in main, by content |
| `integrate/client-connection` | `a04cf02` | 2026-08-29 | already in main, by content |
| `integrate/no-such-room` | `c5962b6` | 2026-08-28 | already in main |
| `integrate/privacy` | `91400db` | 2026-08-28 | already in main |
| `integrate/room-presentation` | `5f09109` | 2026-08-28 | already in main |
| `integrate/room-screen` | `f6e6f7d` | 2026-08-28 | already in main |
| `integrate/run19` | `9df87f5` | 2026-08-28 | already in main |
| `integrate/run20` | `55bde7a` | 2026-08-28 | already in main |
| `integrate/run21` | `298d0e3` | 2026-08-29 | already in main |
| `integrate/run22` | `1596b2c` | 2026-08-29 | already in main |
| `integrate/run23` | `9d85446` | 2026-08-29 | already in main |
| `integrate/run24` | `c6484ce` | 2026-08-29 | already in main |
| `integrate/run25` | `a23d51e` | 2026-08-29 | already in main |
| `integrate/run26` | `3267570` | 2026-08-29 | already in main |
| `integrate/run27` | `70dd7b5` | 2026-08-29 | already in main |
| `integrate/run28` | `c949205` | 2026-08-30 | already in main |
| `integrate/run29` | `05f08c9` | 2026-08-31 | already in main |
| `integrate/run30` | `f2f70cd` | 2026-08-31 | already in main |
| `integrate/run31` | `572a567` | 2026-09-01 | already in main |
| `integrate/run32` | `a2c9d64` | 2026-09-01 | already in main |
| `integrate/run33` | `2bcac1d` | 2026-09-02 | already in main |
| `integrate/run34` | `74f6d4b` | 2026-09-03 | already in main |
| `integrate/run39` | `06f04d6` | 2026-09-07 | already in main |
| `integrate/run44` | `4d72855` | 2026-09-14 | already in main, by content |
| `integrate/run44-client2` | `754fa37` | 2026-09-14 | landed squashed as pull request 43 |
| `integrate/run45-139` | `c8e0210` | 2026-09-15 | landed squashed as pull request 44 |
| `integrate/run46` | `45667a1` | 2026-09-15 | already in main, by content |
| `integrate/run47` | `4018c35` | 2026-09-16 | landed squashed as pull request 48 |
| `integrate/turn-loop` | `4a66cab` | 2026-08-28 | already in main |
| `ops/app-links` | `2f19312` | 2026-08-29 | already in main |
| `ops/compose-environment` | `d861f5d` | 2026-08-28 | already in main |
| `ops/deploy-per-environment` | `45c1bd0` | 2026-08-28 | already in main |
| `ops/screenshot-join` | `8402449` | 2026-08-28 | already in main |
| `ops/screenshot-nav` | `91d1a4b` | 2026-08-28 | already in main |
| `ops/store-graphics` | `58ef4be` | 2026-08-28 | already in main |
| `ops/store-graphics-r3` | `e7cc619` | 2026-08-28 | replaced by the die artwork, ops/store-graphics-v2, pull request 28 |
| `order/116-reconnect-stall` | `6d8b55f` | 2026-09-04 | diagnostics for a stall the resume watchdog closed in run 39; never opened as a pull request |
| `order/120-turn-timer-proof` | `8685fe5` | 2026-09-06 | already in main |
| `order/128-store-screenshots` | `d2a8772` | 2026-09-08 | landed squashed as pull request 32 |
| `order/129-app-icon` | `e017b4d` | 2026-09-08 | already in main, by content |
| `order/130-wt` | `3b2b09e` | 2026-09-08 | pull request 35 closed unmerged; replaced by order 133, pull request 39 |
| `order/131-wt` | `f2b3e19` | 2026-09-08 | already in main, by content |
| `order/132a-wt` | `78a6743` | 2026-09-08 | landed squashed as pull request 33 |
| `order/132b-wt` | `db4ad8a` | 2026-09-08 | already in main, by content |
| `order/133-wt` | `c2906b6` | 2026-09-13 | already in main, by content |
| `order/134-wt` | `7fa3cdf` | 2026-09-14 | already in main |
| `order/135-wt` | `9a92ba0` | 2026-09-14 | landed squashed as pull request 41 |
| `order/136-wt` | `3cf4e33` | 2026-09-14 | landed squashed as pull request 41 |
| `order/137-wt` | `0a24ebe` | 2026-09-14 | landed squashed as pull request 43 |
| `order/138-wt` | `6a0f4ae` | 2026-09-14 | landed squashed as pull request 43 |
| `order/139-wt` | `d6a219f` | 2026-09-14 | landed squashed as pull request 44 |
| `order/140-wt` | `09cbc4b` | 2026-09-14 | already in main, by content |
| `order/141-wt` | `a595985` | 2026-09-14 | landed squashed as pull request 44 |
| `order/142-wt` | `f39acfb` | 2026-09-15 | already in main, by content |
| `order/143-wt` | `7baa23a` | 2026-09-15 | landed squashed as pull request 46 |
| `order/147-wt` | `05004e7` | 2026-09-15 | landed squashed as pull request 48 |
| `order/151-wt` | `194f7b0` | 2026-09-16 | already in main, by content |
| `order/turn-timer-expiry` | `373fcd8` | 2026-09-05 | already in main |
| `server/container-deploy` | `6f0ab56` | 2026-08-27 | already in main |
| `server/dice-steering` | `d691c81` | 2026-08-28 | already in main |
| `server/fairness-lobby` | `2a3db05` | 2026-08-28 | already in main |
| `server/fairness-tests` | `8522d56` | 2026-08-28 | already in main |
| `server/fairness-tests-r2` | `dd0fcce` | 2026-08-28 | already in main |
| `server/room-registry` | `1ba7e64` | 2026-08-23 | already in main |
| `server/set-seed-no-such-room` | `c9aa962` | 2026-08-28 | already in main |
| `server/simulator` | `ec25b90` | 2026-08-28 | already in main |
| `server/turn-after-start-r2` | `55bde7a` | 2026-08-28 | already in main |
| `server/turn-after-start-tests` | `140ac43` | 2026-08-28 | already in main |
| `server/turn-loop` | `4caa0e6` | 2026-08-28 | already in main |
| `server/turn-loop-tests` | `347c9eb` | 2026-08-28 | already in main |
| `server/wire-layer` | `7e34140` | 2026-08-28 | already in main |
| `spec/turn-after-start` | `b15a9be` | 2026-08-28 | already in main |
| `spine/face-engine` | `70a5141` | 2026-08-28 | already in main |
| `spine/face-in-intention` | `d9813d1` | 2026-08-28 | already in main |
| `spine/face-tests` | `8f4a392` | 2026-08-28 | already in main |
| `spine/fair-dice` | `155d274` | 2026-08-28 | already in main |
| `spine/specs-and-verifier` | `892fa28` | 2026-08-24 | already in main |
| `spine/workspace` | `4aa5e9a` | 2026-08-20 | already in main |
| `test/app-links` | `7dec340` | 2026-08-29 | already in main |
| `test/dice-oracle-window` | `19a527f` | 2026-08-28 | already in main |
| `test/room-connection` | `4b29393` | 2026-08-29 | already in main |
| `test/snapshot-rulings` | `f2a3447` | 2026-08-29 | already in main |
| `ux/A-c1` | `3bf4f42` | 2026-09-16 | already in main |
| `ux/B-c1` | `e1328a9` | 2026-09-17 | already in main |
| `ux/C-c1` | `1b10bb9` | 2026-09-18 | merged into main on 2026-09-21, inside ux/D-c1 |
| `ux/D-c1` | `2bdcfc2` | 2026-09-18 | merged into main on 2026-09-21 |
| `ux/program` | `c0d4b7a` | 2026-09-18 | merged into main on 2026-09-21, inside ux/D-c1 |
| `ux/spike-A-c1-board-lobby` | `86b0206` | 2026-09-16 | spike; PROGRAM.md says a spike is never merged |
| `ux/spike-A-c1-die-create` | `32bf576` | 2026-09-16 | spike; PROGRAM.md says a spike is never merged |
| `ux/spike-A-c1-swipe-leave` | `cd68f74` | 2026-09-16 | spike; PROGRAM.md says a spike is never merged |
| `ux/spike-B-c1-hand-scheme` | `ac4f4e0` | 2026-09-17 | spike; PROGRAM.md says a spike is never merged |
| `ux/spike-B-c1-neon-underfelt` | `7434394` | 2026-09-17 | spike; PROGRAM.md says a spike is never merged |
| `ux/spike-C-c1-forced-chain` | `2bff438` | 2026-09-17 | spike; PROGRAM.md says a spike is never merged |
| `work/093` | `ca85904` | 2026-08-29 | landed in run 29 and evolved since |
| `work/097` | `a33cda6` | 2026-08-30 | landed in run 29 and evolved since |
| `work/106` | `c7ce174` | 2026-09-01 | already in main |
| `work/106b` | `775458e` | 2026-09-01 | already in main |
| `wt/079` | `d0349bf` | 2026-08-29 | already in main |
| `wt/080` | `18af0b4` | 2026-08-29 | already in main |
| `wt/081` | `648ce80` | 2026-08-29 | already in main |
| `wt/081b` | `8321abb` | 2026-08-29 | already in main |
| `wt/083` | `e94eae3` | 2026-08-29 | already in main |
| `wt/084` | `83be33a` | 2026-08-29 | already in main |
| `wt/085` | `f3fb940` | 2026-08-29 | already in main |
| `wt/086` | `2b5bbb0` | 2026-08-29 | already in main |
| `wt/087` | `3637272` | 2026-08-29 | already in main |
| `wt/applinks-merge` | `7733c2f` | 2026-08-29 | already in main, by content |
| `wt/blind2581` | `488e8fe` | 2026-08-29 | already in main, by content |
