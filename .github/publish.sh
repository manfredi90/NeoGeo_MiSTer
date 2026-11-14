#!/bin/bash
# Publish the SD card package of a build on the savestates branch, as the upstream cores do with
# their RBFs. Usage: publish.sh "<timing description>", in a full clone with HEAD = the build and
# the package in sd/.
#   releases/<core>_SS_<date>.rbf   the core
#   releases/sd/...                 the other files of the package (if any), by SD card path
#   releases/ss-files.json          SD card path -> repo path of each file of the current package,
#                                   read by the Downloader database (manfredi90/MiSTer_db)
# The commit message carries the release notes.
set -e
built=$(git rev-parse HEAD)
notes=$(bash .github/release-notes.sh "$1")   # compares with the previous publish

git fetch -q origin savestates
git checkout -q -B savestates origin/savestates
git merge-base --is-ancestor "$built" HEAD || { echo "::error::savestates no longer contains $built"; exit 1; }
[ "$(git rev-parse HEAD)" = "$built" ] || notes="$notes

Built from $(git rev-parse --short "$built"), savestates has moved on since."

rbf=$(cd sd && ls _Console/*.rbf)
mkdir -p releases
cp "sd/$rbf" releases/
rm -rf releases/sd
python3 - "$rbf" <<'EOF'
import json, os, shutil, sys
rbf = sys.argv[1]
files = {rbf: "releases/" + os.path.basename(rbf)}
for root, _, names in os.walk("sd"):
    for n in names:
        p = os.path.relpath(os.path.join(root, n), "sd")
        if p != rbf:
            dst = os.path.join("releases/sd", p)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(os.path.join("sd", p), dst)
            files[p] = dst
with open("releases/ss-files.json", "w") as f:
    json.dump(dict(sorted(files.items())), f, indent=1)
    f.write("\n")
EOF

git add -A releases
git -c user.name=manfredi90 -c user.email=manfredi90@gmail.com \
  commit -q -m "Release $(basename "$rbf" .rbf)" -m "$notes"
for i in 1 2 3 4 5; do
  git push -q origin HEAD:savestates && { echo "::notice::published $(basename "$rbf")"; exit 0; }
  sleep 10
  git pull -q --rebase origin savestates
done
exit 1
