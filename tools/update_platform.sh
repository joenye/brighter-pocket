#!/bin/bash
# Move platform/ to another Tolkara commit, byte for byte, and pin it.
#
# usage: tools/update_platform.sh <commit or branch>   (default: upstream main)
#
# Fetches Tolkara into .ref/tolkara (ignored), replaces platform/ with that commit's tree,
# writes pocket/platform.lock, and prepares the tree so a patch that no longer applies or
# an overlay that now collides is named at once. Commit platform/ and the lock together.
set -euo pipefail
cd "$(dirname "$0")/.."
REF=${1:-main}
UPSTREAM=$(sed -n 's/^upstream=//p' pocket/platform.lock)
if [ -d .ref/tolkara/.git ]; then
    git -C .ref/tolkara fetch -q origin
else
    mkdir -p .ref && git clone -q "$UPSTREAM" .ref/tolkara
fi
COMMIT=$(git -C .ref/tolkara rev-parse -q --verify "origin/$REF^{commit}" || git -C .ref/tolkara rev-parse --verify "$REF^{commit}")
TREE=$(git -C .ref/tolkara rev-parse "$COMMIT^{tree}")
DATE=$(git -C .ref/tolkara show -s --format=%cs "$COMMIT")
rm -rf platform && mkdir platform
git -C .ref/tolkara archive "$COMMIT" | tar -x -C platform
cat > pocket/platform.lock <<EOF
# The Tolkara commit vendored at platform/, byte for byte (tools/prepare.py compares
# git's tree hash of platform/ with the tree below). To move the pin: tools/update_platform.sh.
upstream=$UPSTREAM
commit=$COMMIT
tree=$TREE
date=$DATE
EOF
python3 tools/prepare.py
echo "platform/ is Tolkara ${COMMIT:0:12} ($DATE); run tests/run.sh, then commit platform/ and pocket/platform.lock"
