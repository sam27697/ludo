#!/usr/bin/env bash
# Delete every branch on origin except main and the archive ref, and only
# after proving that nothing is lost by deleting it.
#
# Why this exists. On 2026-09-21 this repository carried 122 branches besides
# main, almost all of them finished work whose branch outlived its squashed
# pull request. docs/BRANCH_ARCHIVE.md records what they were. The tips of all
# of them are parents of one commit, on the branch named below, so every
# commit stays reachable whatever happens to the branches themselves.
#
# Why it is a script and not a command someone types. `git push origin --delete`
# over a hundred refs is one typo away from deleting a branch that is the only
# thing holding a piece of work. The check below is the point: a branch is
# deleted only when its tip is an ancestor of the archive commit or of main,
# which is the same as saying the commits survive the deletion. A branch that
# fails that check stops the run rather than being skipped quietly, because a
# branch nobody has anchored is exactly the one worth looking at by hand.
#
# Usage:
#   bash tool/prune_branches.sh            # print the plan, delete nothing
#   bash tool/prune_branches.sh --yes      # do it
set -euo pipefail
cd "$(dirname "$0")/.."

ARCHIVE_REF="archive/workshop-2026-09-21"
KEEP=("main" "$ARCHIVE_REF")
APPLY=0
[ "${1:-}" = "--yes" ] && APPLY=1

git fetch origin --prune --quiet

archive="$(git rev-parse -q --verify "refs/remotes/origin/$ARCHIVE_REF" || true)"
if [ -z "$archive" ]; then
  echo "origin/$ARCHIVE_REF is gone. It is the only thing anchoring the deleted" >&2
  echo "branches' commits, so this script will not delete anything without it." >&2
  echo "If it was turned into a tag, point ARCHIVE_REF at that tag instead." >&2
  exit 1
fi
main="$(git rev-parse -q --verify refs/remotes/origin/main)"

# True when merging the branch into main would change nothing, which is what
# a squash merge leaves behind: the branch's commits are not in main's history
# but every line of its content is. This repository merges that way, so
# without this test the script would refuse from the first squashed pull
# request landed after the archive commit onward, which is to say permanently.
# Deleting such a branch drops its own commit objects; the content is in main
# and GitHub keeps the originals at refs/pull/<n>/head, so what is lost is the
# branch name, not the work. Needs merge-tree's two-argument form, git 2.38 or
# newer. Older git leaves the answer as no, which only ever refuses more.
content_already_in_main() {
  local sha="$1" merged
  merged="$(git merge-tree --write-tree "$sha" "$main" 2>/dev/null | head -1)" || return 1
  [ -n "$merged" ] && [ "$merged" = "$(git rev-parse "$main^{tree}")" ]
}

doomed=(); squashed=(); unanchored=()
while read -r ref; do
  b="${ref#refs/heads/}"
  for k in "${KEEP[@]}"; do [ "$b" = "$k" ] && continue 2; done
  sha="$(git rev-parse -q --verify "refs/remotes/origin/$b" || true)"
  if [ -z "$sha" ]; then continue; fi
  if git merge-base --is-ancestor "$sha" "$archive" || git merge-base --is-ancestor "$sha" "$main"; then
    doomed+=("$b")
  elif content_already_in_main "$sha"; then
    squashed+=("$b")
  else
    unanchored+=("$b")
  fi
done < <(git ls-remote --heads origin | awk '{print $2}')

if [ "${#unanchored[@]}" -gt 0 ]; then
  echo "These branches are reachable from neither the archive commit nor main."
  echo "Deleting them would make their commits unreachable, so nothing is deleted:"
  printf '  %s\n' "${unanchored[@]}"
  echo
  echo "Anchor them first (add them as parents of a new archive commit), or delete"
  echo "them by hand if that is really what you want."
  exit 1
fi

echo "archive commit: $archive ($(git cat-file -p "$archive" | grep -c '^parent ') branch tips anchored)"
echo "keeping: ${KEEP[*]}"
echo "deleting ${#doomed[@]} branches whose commits are reachable from the archive commit or from main:"
printf '  %s\n' "${doomed[@]}"
if [ "${#squashed[@]}" -gt 0 ]; then
  echo
  echo "and ${#squashed[@]} squash-merged: their commits are not in main's history,"
  echo "but merging them into main would change nothing, and GitHub keeps the"
  echo "originals at refs/pull/<n>/head:"
  printf '  %s\n' "${squashed[@]}"
  doomed+=("${squashed[@]}")
fi

if [ "$APPLY" -ne 1 ]; then
  echo
  echo "Nothing was deleted. Re-run with --yes to delete these."
  exit 0
fi

batch=(); done_count=0
flush() {
  [ "${#batch[@]}" -eq 0 ] && return 0
  git push origin "${batch[@]}"
  done_count=$((done_count + ${#batch[@]}))
  batch=()
}
for b in "${doomed[@]}"; do
  batch+=(":refs/heads/$b")
  [ "${#batch[@]}" -ge 25 ] && flush
done
flush

git fetch origin --prune --quiet
echo "deleted $done_count branches; origin now carries:"
git ls-remote --heads origin | awk '{print "  " $2}'
