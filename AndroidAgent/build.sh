#!/bin/bash
# Builds the Android agent and puts it where the Voly app target picks it
# up as resources (Voly/AndroidAgentPayload):
#
#   voly-agent.dex          the agent, Java, loaded from memory
#   voly-agent-<abi>.elf    the JVMTI library that loads it, one per ABI
#   voly-agent.version      a hash of the above, used to name the copy on a device
#
# The results are checked in, so building Voly.app does not need the
# Android SDK. Run this after changing anything under AndroidAgent/src.
#
# Needs: a JDK (11+), and from the Android SDK a platform (android.jar),
# build-tools (d8) and the NDK. Locations are found through ANDROID_HOME /
# ANDROID_SDK_ROOT (default ~/Library/Android/sdk) and ANDROID_NDK_HOME.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$HERE/../Voly/AndroidAgentPayload}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
[ -d "$SDK" ] || { echo "error: Android SDK not found (set ANDROID_HOME)" >&2; exit 1; }

newest() { ls -d "$@" 2>/dev/null | sort -V | tail -1; }

PLATFORM="$(newest "$SDK"/platforms/android-*)"
BUILD_TOOLS="$(newest "$SDK"/build-tools/*)"
NDK="${ANDROID_NDK_HOME:-$(newest "$SDK"/ndk/*)}"
[ -f "$PLATFORM/android.jar" ] || { echo "error: no platform in $SDK/platforms (sdkmanager 'platforms;android-35')" >&2; exit 1; }
[ -x "$BUILD_TOOLS/d8" ] || { echo "error: no build-tools in $SDK/build-tools (sdkmanager 'build-tools;35.0.0')" >&2; exit 1; }
[ -d "$NDK" ] || { echo "error: no NDK in $SDK/ndk (sdkmanager 'ndk;27.2.12479018')" >&2; exit 1; }
TOOLCHAIN="$(newest "$NDK"/toolchains/llvm/prebuilt/*)"
[ -x "$TOOLCHAIN/bin/clang" ] || { echo "error: no clang in $NDK" >&2; exit 1; }

# The agent needs nothing newer than Android 8 (API 26), the first release
# that can attach an agent to a running app at all.
MIN_API=26

echo "Compiling the agent (Java)…"
mkdir -p "$WORK/classes" "$WORK/dex"
find "$HERE/src/main/java" -name '*.java' > "$WORK/sources"
javac -source 8 -target 8 -Xlint:-options -nowarn \
  -bootclasspath "$PLATFORM/android.jar:$BUILD_TOOLS/core-lambda-stubs.jar" \
  -d "$WORK/classes" @"$WORK/sources"
(cd "$WORK/classes" && find . -name '*.class' > "$WORK/classlist")
(cd "$WORK/classes" && "$BUILD_TOOLS/d8" --release --min-api "$MIN_API" \
  --lib "$PLATFORM/android.jar" --output "$WORK/dex" @"$WORK/classlist")

mkdir -p "$OUT"
rm -f "$OUT"/voly-agent*
cp "$WORK/dex/classes.dex" "$OUT/voly-agent.dex"

echo "Compiling the loader (C)…"
for PAIR in arm64-v8a:aarch64-linux-android x86_64:x86_64-linux-android \
            armeabi-v7a:armv7a-linux-androideabi x86:i686-linux-android; do
  ABI="${PAIR%%:*}"
  TRIPLE="${PAIR##*:}"
  "$TOOLCHAIN/bin/clang" --target="$TRIPLE$MIN_API" -shared -fPIC -O2 -Wall -Wextra -Werror \
    -fvisibility=hidden -Wl,-z,max-page-size=16384 -Wl,--build-id=none \
    -o "$OUT/voly-agent-$ABI.elf" "$HERE/src/main/cpp/voly_jvmti_agent.c" -llog
  "$TOOLCHAIN/bin/llvm-strip" --strip-unneeded "$OUT/voly-agent-$ABI.elf"
done

# One hash over everything a device gets.
if command -v shasum >/dev/null 2>&1; then HASH="shasum -a 256"; else HASH="sha256sum"; fi
cat "$OUT/voly-agent.dex" "$OUT"/voly-agent-*.elf | $HASH | cut -c1-16 > "$OUT/voly-agent.version"

echo "Built into $OUT:"
ls -l "$OUT"
