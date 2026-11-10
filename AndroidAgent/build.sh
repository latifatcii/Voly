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
#   AndroidAgent/build.sh [--java-only] [<output directory>]
#
# --java-only rebuilds voly-agent.dex and keeps the loaders that are in the
# output directory: for a change to the Java when the NDK isn't installed.
# It is refused when the loader's source is newer than the loaders.
#
# Needs: a JDK (11+), and from the Android SDK a platform (android.jar),
# build-tools (d8) and the NDK. Locations are found through ANDROID_HOME /
# ANDROID_SDK_ROOT (default ~/Library/Android/sdk) and ANDROID_NDK_HOME; the
# JDK inside Android Studio is used when no `javac` is on the PATH.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAVA_ONLY=0
if [ "${1:-}" = "--java-only" ]; then JAVA_ONLY=1; shift; fi
OUT="${1:-$HERE/../Voly/AndroidAgentPayload}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
[ -d "$SDK" ] || { echo "error: Android SDK not found (set ANDROID_HOME)" >&2; exit 1; }

newest() { ls -d "$@" 2>/dev/null | sort -V | tail -1 || true; }   # nothing there is an empty answer, not an error

PLATFORM="$(newest "$SDK"/platforms/android-*)"
BUILD_TOOLS="$(newest "$SDK"/build-tools/*)"
NDK="${ANDROID_NDK_HOME:-$(newest "$SDK"/ndk/*)}"
[ -f "$PLATFORM/android.jar" ] || { echo "error: no platform in $SDK/platforms (sdkmanager 'platforms;android-35')" >&2; exit 1; }
[ -x "$BUILD_TOOLS/d8" ] || { echo "error: no build-tools in $SDK/build-tools (sdkmanager 'build-tools;35.0.0')" >&2; exit 1; }
if [ "$JAVA_ONLY" = 0 ]; then
  [ -d "$NDK" ] || { echo "error: no NDK in $SDK/ndk (sdkmanager 'ndk;27.2.12479018'), or pass --java-only" >&2; exit 1; }
  TOOLCHAIN="$(newest "$NDK"/toolchains/llvm/prebuilt/*)"
  [ -x "$TOOLCHAIN/bin/clang" ] || { echo "error: no clang in $NDK" >&2; exit 1; }
else
  for ABI in arm64-v8a x86_64 armeabi-v7a x86; do
    LOADER="$OUT/voly-agent-$ABI.elf"
    [ -f "$LOADER" ] || { echo "error: --java-only needs the loaders in $OUT ($LOADER is missing)" >&2; exit 1; }
    # Stale when the source has uncommitted changes, or the last commit to
    # touch either of the two touched the source and not the loader.
    if [ -n "$(cd "$HERE" && git status --porcelain -- src/main/cpp 2>/dev/null)" ] \
       || [ "$(cd "$HERE" && git log -1 --format=%H -- "$LOADER" 2>/dev/null)" \
            != "$(cd "$HERE" && git log -1 --format=%H -- src/main/cpp "$LOADER" 2>/dev/null)" ]; then
      echo "error: the loader's source changed after $LOADER was built; a full build (with the NDK) is needed" >&2
      exit 1
    fi
  done
fi
# macOS has a `javac` that only says no JDK is installed: ask it for its version.
if ! javac -version >/dev/null 2>&1; then
  STUDIO_JDK="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
  [ -x "$STUDIO_JDK/bin/javac" ] || { echo "error: no javac on the PATH and no Android Studio JDK" >&2; exit 1; }
  export PATH="$STUDIO_JDK/bin:$PATH"
fi

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
if [ "$JAVA_ONLY" = 0 ]; then rm -f "$OUT"/voly-agent*; else rm -f "$OUT/voly-agent.dex" "$OUT/voly-agent.version"; fi
cp "$WORK/dex/classes.dex" "$OUT/voly-agent.dex"

if [ "$JAVA_ONLY" = 0 ]; then
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
else
  echo "Keeping the loaders in $OUT."
fi

# One hash over everything a device gets.
if command -v shasum >/dev/null 2>&1; then HASH="shasum -a 256"; else HASH="sha256sum"; fi
cat "$OUT/voly-agent.dex" "$OUT"/voly-agent-*.elf | $HASH | cut -c1-16 > "$OUT/voly-agent.version"

echo "Built into $OUT:"
ls -l "$OUT"
