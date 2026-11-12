#!/bin/bash
# Release notes for build.yml: the upstream commit the build sits on, the timing of the kept seed,
# what changed since the latest full release, and a warning when those changes touch files that
# hold savestate logic (states saved with the previous release might then not load).
# Usage: release-notes.sh "<timing description>"   (run in a full clone, HEAD = the build)
set -e
up=origin/master
git rev-parse -q --verify "$up" > /dev/null || up=origin/main
base=$(git merge-base HEAD "$up")

echo "Built on upstream $(git log -1 --format='%h (%ad)' --date=short "$base"), savestate branch $(git rev-parse --short HEAD)."
echo "Timing, $1."

prev=$(gh release view --json tagName --jq .tagName 2> /dev/null || true)   # latest full release
[ -n "$prev" ] && git rev-parse -q --verify "refs/tags/$prev" > /dev/null || exit 0
pbase=$(git merge-base "$prev" "$up")

echo
echo "### Changes since $prev"
upstream=$(git log --no-merges --format='- %s (%h)' "$pbase..$base")
ours=$(git log --no-merges --format='- %s (%h)' "$prev..HEAD" --not "$up" -- . ':!.github')
echo "Upstream:"; echo "${upstream:-- none}"
echo "Savestate branch:"; echo "${ours:-- none}"

# files the savestate patch changes, and those of them changed since the previous release
patch=$(git diff --name-only "$base" HEAD -- rtl '*.sv' '*.v' '*.vhd' ':!sim' ':!savestate' ':!.github' | sort)
touched=$(git diff --name-only "$prev" HEAD | sort)
risky=$(comm -12 <(echo "$patch") <(echo "$touched"))
if [ -n "$risky" ]; then
  echo
  echo "> [!WARNING]"
  echo "> These changes touch files with savestate logic: states saved with $prev may not load."
  echo "$risky" | sed 's/^/> - /'
fi
