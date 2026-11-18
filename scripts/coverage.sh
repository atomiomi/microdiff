#!/bin/bash
# Runs the unit and UI tests with code coverage (perf tests are skipped) and prints line and
# function coverage per file under Sources/, worst first, plus the totals.
#   scripts/coverage.sh                 full run
#   scripts/coverage.sh --filter Lexer  extra arguments go to `swift test`
# Needs jq (ships with macOS 15+). Works with only the Command Line Tools installed.
set -euo pipefail
cd "$(dirname "$0")/.."

COV_DIR=".build/arm64-apple-macosx/debug/codecov"
# Old raw profiles from earlier builds would be merged in and skew the numbers.
rm -f "$COV_DIR"/*.profraw "$COV_DIR"/default.profdata

./scripts/test.sh --enable-code-coverage --skip MicroDiffPerfTests "$@" > .build/coverage-test.log 2>&1 \
  || { tail -40 .build/coverage-test.log; echo "tests failed, no coverage report" >&2; exit 1; }
grep -E "Test run with" .build/coverage-test.log || true

BIN=".build/arm64-apple-macosx/debug/MicroDiffPackageTests.xctest/Contents/MacOS/MicroDiffPackageTests"
xcrun llvm-cov export -summary-only -instr-profile="$COV_DIR/default.profdata" "$BIN" \
  -ignore-filename-regex='/(Tests|\.build)/' \
| jq -r --arg root "$PWD/" '
    [.data[0].files[] | {f: (.filename | sub($root; "")), s: .summary}
     | select(.f | startswith("Sources/"))] as $files
    | def pct(c; n): if n == 0 then 100 else (c * 1000 / n | round) / 10 end;
      ($files | sort_by(.s.lines.percent, .s.functions.percent)[]
       | [.f, "\(pct(.s.lines.covered; .s.lines.count))", "\(.s.lines.covered)/\(.s.lines.count)",
          "\(pct(.s.functions.covered; .s.functions.count))", "\(.s.functions.covered)/\(.s.functions.count)"]
       | @tsv),
      ([$files[].s.lines.covered] | add) as $lc | ([$files[].s.lines.count] | add) as $ln
      | ([$files[].s.functions.covered] | add) as $fc | ([$files[].s.functions.count] | add) as $fn
      | ["TOTAL", "\(pct($lc; $ln))", "\($lc)/\($ln)", "\(pct($fc; $fn))", "\($fc)/\($fn)"] | @tsv' \
| { printf 'file\tlines%%\tlines\tfuncs%%\tfuncs\n'; cat; } | column -t -s $'\t'
