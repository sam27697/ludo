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

The table covers every branch on the remote except `main` and the anchor
itself, so the three refs that postdate the original count are in it too: the
branch this consolidation was assembled on, a throwaway left over from
measuring which ref namespaces the push credentials accept (they take
`refs/heads/*` and refuse deletions, tags and every other namespace, which is
why the anchor is a branch), and `integrate/run48`, the first branch
squash-merged after the anchor was built and the shape every later one will
have: its commits are not in `main`'s history, but merging it into `main` would
change nothing and GitHub keeps its originals at `refs/pull/<n>/head`.
`tool/prune_branches.sh` recognises all of them.

The commit column is the history as it stands after the repository was rewritten
on 2026-09-21, which renumbered every commit in it. Branch names and contents
came through unchanged, and the anchor was rewritten with everything else, so it
still holds all 121 tips. A clone taken before that rewrite carries the old
numbers and will not match this table.

| branch | commit | last commit | disposition |
|---|---|---|---|
| `asam/youthful-curie-6ic7v5` | see `main` | 2026-09-21 | the branch this consolidation was assembled on; its commits reach main through pull requests 54 and 56, so no tip is pinned here |
| `client/board-geometry` | `a53b7b9` | 2026-08-28 | already in main |
| `client/board-tests` | `8b227f7` | 2026-08-28 | already in main |
| `client/board-widget` | `4f85646` | 2026-08-28 | already in main |
| `client/release-signing` | `b3e3ff1` | 2026-08-28 | already in main |
| `client/room-connection` | `fb9df7b` | 2026-08-29 | already in main |
| `client/screenshot-lag` | `32e62ad` | 2026-08-28 | already in main |
| `client/shell` | `5f9fefa` | 2026-08-28 | already in main |
| `client/wire-codec` | `31830eb` | 2026-08-29 | already in main |
| `client/wire-codec-tests` | `ddd04ba` | 2026-08-29 | already in main |
| `client/ws-transport` | `4d42615` | 2026-08-29 | already in main |
| `cursor/home-ui-felt-die-9a17` | `61f0219` | 2026-09-10 | already in main |
| `cursor/setup-cloud-agent-environment-edc6` | `494dac5` | 2026-09-10 | merged into main on 2026-09-21, pull request 38 |
| `fix/static-gate-format` | `2d010d4` | 2026-09-05 | already in main |
| `integrate/board` | `fd6d056` | 2026-08-28 | already in main |
| `integrate/client-codec` | `cf6316e` | 2026-08-29 | already in main, by content |
| `integrate/client-connection` | `d7670e6` | 2026-08-29 | already in main, by content |
| `integrate/no-such-room` | `99bfee6` | 2026-08-28 | already in main |
| `integrate/privacy` | `f2456f8` | 2026-08-28 | already in main |
| `integrate/room-presentation` | `e1424f1` | 2026-08-28 | already in main |
| `integrate/room-screen` | `c647a77` | 2026-08-28 | already in main |
| `integrate/run19` | `effd276` | 2026-08-28 | already in main |
| `integrate/run20` | `dd7ef17` | 2026-08-28 | already in main |
| `integrate/run21` | `c4a9d62` | 2026-08-29 | already in main |
| `integrate/run22` | `dfc0f4e` | 2026-08-29 | already in main |
| `integrate/run23` | `c45f7df` | 2026-08-29 | already in main |
| `integrate/run24` | `555e868` | 2026-08-29 | already in main |
| `integrate/run25` | `74dd6e6` | 2026-08-29 | already in main |
| `integrate/run26` | `4c3f3e0` | 2026-08-29 | already in main |
| `integrate/run27` | `e4b2f2a` | 2026-08-29 | already in main |
| `integrate/run28` | `d4f2b9f` | 2026-08-30 | already in main |
| `integrate/run29` | `7bdd8f7` | 2026-08-31 | already in main |
| `integrate/run30` | `cb8b09b` | 2026-08-31 | already in main |
| `integrate/run31` | `142d9eb` | 2026-09-01 | already in main |
| `integrate/run32` | `b8d46a6` | 2026-09-01 | already in main |
| `integrate/run33` | `0d6c67e` | 2026-09-02 | already in main |
| `integrate/run34` | `6939146` | 2026-09-03 | already in main |
| `integrate/run39` | `bc86343` | 2026-09-07 | already in main |
| `integrate/run44` | `f906c88` | 2026-09-14 | already in main, by content |
| `integrate/run44-client2` | `cebd451` | 2026-09-14 | landed squashed as pull request 43 |
| `integrate/run45-139` | `813be6d` | 2026-09-15 | landed squashed as pull request 44 |
| `integrate/run46` | `d6dc9f1` | 2026-09-15 | already in main, by content |
| `integrate/run47` | `5ae7cb8` | 2026-09-16 | landed squashed as pull request 48 |
| `integrate/run48` | `6567fc8` | 2026-09-21 | landed squashed as pull request 55 |
| `integrate/turn-loop` | `d754ebb` | 2026-08-28 | already in main |
| `ops/app-links` | `af9df92` | 2026-08-29 | already in main |
| `ops/compose-environment` | `2f86818` | 2026-08-28 | already in main |
| `ops/deploy-per-environment` | `37d6d31` | 2026-08-28 | already in main |
| `ops/screenshot-join` | `db4341d` | 2026-08-28 | already in main |
| `ops/screenshot-nav` | `135ee30` | 2026-08-28 | already in main |
| `ops/store-graphics` | `051632f` | 2026-08-28 | already in main |
| `ops/store-graphics-r3` | `c566add` | 2026-08-28 | replaced by the die artwork, ops/store-graphics-v2, pull request 28 |
| `order/116-reconnect-stall` | `5f393a3` | 2026-09-04 | diagnostics for a stall the resume watchdog closed in run 39; never opened as a pull request |
| `order/120-turn-timer-proof` | `c809bc2` | 2026-09-06 | already in main |
| `order/128-store-screenshots` | `43454df` | 2026-09-08 | landed squashed as pull request 32 |
| `order/129-app-icon` | `da2de85` | 2026-09-08 | already in main, by content |
| `order/130-wt` | `c9d166e` | 2026-09-08 | pull request 35 closed unmerged; replaced by order 133, pull request 39 |
| `order/131-wt` | `4024894` | 2026-09-08 | already in main, by content |
| `order/132a-wt` | `686a747` | 2026-09-08 | landed squashed as pull request 33 |
| `order/132b-wt` | `e5fc125` | 2026-09-08 | landed squashed as pull request 36; the proof it added has since been rewritten on main |
| `order/133-wt` | `24f1d3a` | 2026-09-13 | already in main, by content |
| `order/134-wt` | `83d59d2` | 2026-09-14 | already in main |
| `order/135-wt` | `c1431d7` | 2026-09-14 | landed squashed as pull request 41 |
| `order/136-wt` | `70f962e` | 2026-09-14 | landed squashed as pull request 41 |
| `order/137-wt` | `8578fc8` | 2026-09-14 | landed squashed as pull request 43 |
| `order/138-wt` | `16db70a` | 2026-09-14 | landed squashed as pull request 43 |
| `order/139-wt` | `483597b` | 2026-09-14 | landed squashed as pull request 44 |
| `order/140-wt` | `21bca99` | 2026-09-14 | already in main, by content |
| `order/141-wt` | `4bc06d0` | 2026-09-14 | landed squashed as pull request 44 |
| `order/142-wt` | `17a0011` | 2026-09-15 | already in main, by content |
| `order/143-wt` | `618c833` | 2026-09-15 | landed squashed as pull request 46 |
| `order/147-wt` | `be87072` | 2026-09-15 | landed squashed as pull request 48 |
| `order/151-wt` | `32e695b` | 2026-09-16 | already in main, by content |
| `order/turn-timer-expiry` | `1db2dc1` | 2026-09-05 | already in main |
| `probe-branch-test` | `c4a93fe` | 2026-09-17 | throwaway from measuring which ref namespaces the push credentials accept |
| `server/container-deploy` | `d00eeff` | 2026-08-27 | already in main |
| `server/dice-steering` | `1d37ef5` | 2026-08-28 | already in main |
| `server/fairness-lobby` | `ae3162c` | 2026-08-28 | already in main |
| `server/fairness-tests` | `373c370` | 2026-08-28 | already in main |
| `server/fairness-tests-r2` | `03972f9` | 2026-08-28 | already in main |
| `server/room-registry` | `1ba7e64` | 2026-08-23 | already in main |
| `server/set-seed-no-such-room` | `03dfa9d` | 2026-08-28 | already in main |
| `server/simulator` | `f1c97fc` | 2026-08-28 | already in main |
| `server/turn-after-start-r2` | `dd7ef17` | 2026-08-28 | already in main |
| `server/turn-after-start-tests` | `d2f6f3b` | 2026-08-28 | already in main |
| `server/turn-loop` | `c94826f` | 2026-08-28 | already in main |
| `server/turn-loop-tests` | `32056d3` | 2026-08-28 | already in main |
| `server/wire-layer` | `de80558` | 2026-08-28 | already in main |
| `spec/turn-after-start` | `8835dc3` | 2026-08-28 | already in main |
| `spine/face-engine` | `4e94fb8` | 2026-08-28 | already in main |
| `spine/face-in-intention` | `7e42b92` | 2026-08-28 | already in main |
| `spine/face-tests` | `4231432` | 2026-08-28 | already in main |
| `spine/fair-dice` | `6c2528c` | 2026-08-28 | already in main |
| `spine/specs-and-verifier` | `043ca5d` | 2026-08-24 | already in main |
| `spine/workspace` | `4aa5e9a` | 2026-08-20 | already in main |
| `test/app-links` | `dfa8348` | 2026-08-29 | already in main |
| `test/dice-oracle-window` | `01a2d26` | 2026-08-28 | already in main |
| `test/room-connection` | `f62f179` | 2026-08-29 | already in main |
| `test/snapshot-rulings` | `958be15` | 2026-08-29 | already in main |
| `ux/A-c1` | `a5364a9` | 2026-09-16 | already in main |
| `ux/B-c1` | `f1a7db7` | 2026-09-17 | already in main |
| `ux/C-c1` | `a65af26` | 2026-09-18 | merged into main on 2026-09-21, inside ux/D-c1 |
| `ux/D-c1` | `6288fea` | 2026-09-18 | merged into main on 2026-09-21 |
| `ux/program` | `7b0b5e6` | 2026-09-18 | merged into main on 2026-09-21, inside ux/D-c1 |
| `ux/spike-A-c1-board-lobby` | `6449875` | 2026-09-16 | spike; PROGRAM.md says a spike is never merged |
| `ux/spike-A-c1-die-create` | `8e181a7` | 2026-09-16 | spike; PROGRAM.md says a spike is never merged |
| `ux/spike-A-c1-swipe-leave` | `09dc4ac` | 2026-09-16 | spike; PROGRAM.md says a spike is never merged |
| `ux/spike-B-c1-hand-scheme` | `c07a1ad` | 2026-09-17 | spike; PROGRAM.md says a spike is never merged |
| `ux/spike-B-c1-neon-underfelt` | `a40e75b` | 2026-09-17 | spike; PROGRAM.md says a spike is never merged |
| `ux/spike-C-c1-forced-chain` | `01e69c3` | 2026-09-17 | spike; PROGRAM.md says a spike is never merged |
| `work/093` | `05edd4f` | 2026-08-29 | landed in run 29 and evolved since |
| `work/097` | `a60e7a4` | 2026-08-30 | landed in run 29 and evolved since |
| `work/106` | `49f8201` | 2026-09-01 | already in main |
| `work/106b` | `c9562fc` | 2026-09-01 | already in main |
| `wt/079` | `9a4ca05` | 2026-08-29 | already in main |
| `wt/080` | `a46d7c5` | 2026-08-29 | already in main |
| `wt/081` | `8846e0f` | 2026-08-29 | already in main |
| `wt/081b` | `3a95d79` | 2026-08-29 | already in main |
| `wt/083` | `dc849fb` | 2026-08-29 | already in main |
| `wt/084` | `e0d6111` | 2026-08-29 | already in main |
| `wt/085` | `a83afc8` | 2026-08-29 | already in main |
| `wt/086` | `630a06e` | 2026-08-29 | already in main |
| `wt/087` | `3905031` | 2026-08-29 | already in main |
| `wt/applinks-merge` | `39e1521` | 2026-08-29 | already in main, by content |
| `wt/blind2581` | `a2b6e13` | 2026-08-29 | already in main, by content |
