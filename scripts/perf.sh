#!/bin/bash
# Runs the speed and memory budget tests against an optimized build. Every test prints one
# greppable line: `./scripts/perf.sh | grep '^PERF'`.
#
# Two passes, because the memory tests need a different allocator setting:
#  - Timing tests: default allocator (what the app runs with).
#  - Memory tests: MallocLargeCache=0. By default macOS keeps freed big blocks in a cache and hands
#    them out again, so "growth" depends on what ran before. Without the cache, numbers are exact.
#    (It is not used for the timing pass: git child processes inherit it and run much slower.)
set -uo pipefail
cd "$(dirname "$0")/.."

TEST=(./scripts/test.sh -c release --filter MicroDiffPerfTests)

status=0
"${TEST[@]}" --skip 'PerfSuite/Memory' "$@" || status=$?
MallocLargeCache=0 "${TEST[@]}" --skip 'PerfSuite/(CoreCPU|CoreIO|Drawing)' "$@" || status=$?
exit "$status"
