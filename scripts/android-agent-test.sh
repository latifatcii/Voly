#!/bin/bash
# Runs the tests of how the Android agent reads Jetpack Compose content
# (AndroidAgent/tests) against one or more releases of Compose. They run on
# the JVM with Robolectric: no emulator, no device.
#
# The agent reaches into Compose by reflection, and one of the things it
# needs (a layout node's children) is not public API. A new Compose can move
# it; this is how to find out, before an app that ships that Compose does.
#
# Usage: scripts/android-agent-test.sh [<compose version> …]
#        (default: one release from each end of what is supported, and one between)
#
# Needs: a JDK (17+) and the Android SDK (platforms;android-35,
# build-tools;35.0.0) with ANDROID_HOME set. Gradle and the libraries are
# downloaded on the first run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$#" -gt 0 ]; then VERSIONS=("$@"); else VERSIONS=(1.5.4 1.8.3 1.12.1); fi

FAILED=0
for VERSION in "${VERSIONS[@]}"; do
  echo "== Compose $VERSION"
  if "$ROOT/SampleAppAndroid/gradlew" -p "$ROOT/AndroidAgent/tests" --quiet --console=plain \
       testDebugUnitTest -Pcompose="$VERSION"; then
    echo "ok   Compose $VERSION"
  else
    echo "FAIL Compose $VERSION (report: AndroidAgent/tests/build/reports/tests/testDebugUnitTest/index.html)"
    FAILED=1
  fi
done
exit "$FAILED"
