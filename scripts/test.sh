#!/bin/bash
# Runs the tests. Extra arguments go straight to `swift test`.
#   scripts/test.sh                      all tests (debug)
#   scripts/test.sh --filter StatusParser
#   scripts/test.sh --filter Isolated     only the process-wide memory/resource tests
#   MICRODIFF_SOAK=20 scripts/test.sh --filter Isolated      the same, 20 times longer (a soak)
#
# Tests that measure the whole process (live heap, file descriptors, threads) are only meaningful when nothing
# else runs. They skip themselves unless MICRODIFF_ISOLATED=1, and a plain run does a second pass with only them.
# That pass also sets MallocLargeCache=0: otherwise malloc keeps freed big blocks resident and the footprint
# jumps by megabytes depending on what ran before (see scripts/perf.sh).
#
# With only the Command Line Tools installed (no full Xcode), SwiftPM does not find
# the Swift Testing framework by itself, so the paths are added here.
set -euo pipefail
cd "$(dirname "$0")/.."

ARGS=()
DEV="$(xcode-select -p 2>/dev/null || true)"
if [[ "$DEV" == */CommandLineTools ]]; then
  F="$DEV/Library/Developer/Frameworks"
  ARGS+=(--disable-xctest
    -Xswiftc -F -Xswiftc "$F"
    -Xswiftc -plugin-path -Xswiftc "$DEV/usr/lib/swift/host/plugins/testing"
    -Xlinker -F -Xlinker "$F"
    -Xlinker -rpath -Xlinker "$F")
fi

# Optimized builds hide internal declarations from tests; this keeps `@testable import` working with `-c release`.
if [[ " $* " == *" release "* ]]; then
  ARGS+=(-Xswiftc -enable-testing)
fi

if [[ " $* " == *" --filter "* || " $* " == *" --skip "* ]]; then
  # A chosen subset: the isolated tests run only when they are what was asked for.
  if [[ " $* " == *Isolated* ]]; then export MICRODIFF_ISOLATED=1 MallocLargeCache=0; ARGS+=(--no-parallel); fi
  exec swift test "${ARGS[@]}" "$@"
fi

status=0
swift test "${ARGS[@]}" "$@" || status=$?
MICRODIFF_ISOLATED=1 MallocLargeCache=0 swift test "${ARGS[@]}" "$@" --no-parallel --filter Isolated || status=$?
exit "$status"
