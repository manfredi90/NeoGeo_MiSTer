#!/bin/bash
# Release notes for build.yml: the upstream commit the build sits on, the timing of the kept seed,
# what changed since the latest full release, and a warning when those changes touch files that
# hold savestate logic (states saved with the previous release might then not load).
# Usage: release-notes.sh "<timing description>"   (run in a full clone, HEAD = the build)
set -e
# the upstream core itself, so that a build made before the nightly sync is described right too
parent=$(gh api "repos/$GITHUB_REPOSITORY" --jq '.parent.full_name + " " + .parent.default_branch' 2> /dev/null || true)
if [ -n "$GITHUB_REPOSITORY" ] && [ -n "$parent" ] && git fetch -q "https://github.com/${parent% *}" "${parent#* }"; then
  up=$(git rev-parse FETCH_HEAD)
else
  up=origin/master
  git rev-parse -q --verify "$up" > /dev/null || up=origin/main
fi
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
patch=$(git diff --name-only "$base" HEAD -- rtl '*.sv' '*.v' '*.vhd' ':!sim' ':!savestate' ':!.github' ':!rtl/md_core_ss.*' | sort)
touched=$(git diff --name-only "$prev" HEAD | sort)
risky=$(comm -12 <(echo "$patch") <(echo "$touched"))
if [ -n "$risky" ]; then
  echo
  echo "> [!WARNING]"
  echo "> These changes touch files with savestate logic: check that states saved with $prev still load."
  echo "$risky" | sed 's/^/> - /'
fi

# what a core adds of its own (e.g. a savestate layout change and how to convert)
[ ! -f .github/release-notes-extra.sh ] || bash .github/release-notes-extra.sh "$prev"
