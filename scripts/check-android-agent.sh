#!/bin/bash
# Checks that the Android agent Voly.app bundles (Voly/AndroidAgentPayload) is
# whole: every file build.sh produces is there, and voly-agent.version is the
# hash of the others. A file changed by hand, or half a rebuild checked in,
# fails here.
#
# Usage: scripts/check-android-agent.sh [<directory>]
set -euo pipefail

DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)/Voly/AndroidAgentPayload}"
for FILE in voly-agent.dex voly-agent.version \
            voly-agent-arm64-v8a.elf voly-agent-x86_64.elf voly-agent-armeabi-v7a.elf voly-agent-x86.elf; do
    [ -f "$DIR/$FILE" ] || { echo "missing $DIR/$FILE"; exit 1; }
done

# The same hash AndroidAgent/build.sh writes.
if command -v shasum >/dev/null 2>&1; then HASH="shasum -a 256"; else HASH="sha256sum"; fi
ACTUAL="$(cat "$DIR/voly-agent.dex" "$DIR"/voly-agent-*.elf | $HASH | cut -c1-16)"
RECORDED="$(tr -d '[:space:]' < "$DIR/voly-agent.version")"
if [ "$ACTUAL" != "$RECORDED" ]; then
    echo "voly-agent.version says $RECORDED but the files hash to $ACTUAL: run AndroidAgent/build.sh"
    exit 1
fi
echo "Android agent $RECORDED: files match their version"
