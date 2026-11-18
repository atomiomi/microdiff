#!/bin/bash
# Runs the real app through a scripted soak under the `leaks` tool and fails when leaks are reported.
#
#   scripts/leaks.sh            200 rounds (2 to 3 minutes)
#   scripts/leaks.sh 1000       a longer soak
#
# The app runs offscreen (`--soak`): no window, no Dock icon, it never takes focus. It opens a throwaway demo
# repository, starts its file watcher, and repeats a day's activity (rescans, tabs, diff/read, folds, scrolling,
# sidebar, resizes, edit mode: type, save, leave). Meanwhile this script changes the repository under it: edits,
# files added and deleted in bulk, branch switches. At exit `leaks` looks for memory nothing points to any more.
#
# Exit status: 0 no leaks, 1 leaks found (the report is printed), 2 something else went wrong.
set -uo pipefail
cd "$(dirname "$0")/.."

ROUNDS="${1:-200}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/microdiff-leaks.XXXXXX")"
CHURN_PID=""
cleanup() {
  [[ -n "$CHURN_PID" ]] && kill "$CHURN_PID" 2>/dev/null && wait "$CHURN_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

swift build >/dev/null || { echo "leaks.sh: build failed" >&2; exit 2; }
APP="$(swift build --show-bin-path)/MicroDiff"
REPO="$(scripts/make-demo-repo.sh "$WORK/demo" | tail -1)"
[[ -d "$REPO/.git" ]] || { echo "leaks.sh: could not make the demo repository" >&2; exit 2; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
g() { git -C "$REPO" -c user.name=Soak -c user.email=soak@example.com -c commit.gpgsign=false "$@" >/dev/null 2>&1; }
g checkout -q -b soak-side && g commit -q --allow-empty -m side && g checkout -q -

# The repository keeps changing while the app soaks.
(
  i=0
  while true; do
    i=$((i + 1))
    echo "soak edit $i" >> "$REPO/README.md"
    if (( i % 2 )); then
      mkdir -p "$REPO/soak-bulk" && for k in $(seq 1 40); do echo "$k" > "$REPO/soak-bulk/f$k.txt"; done
    else
      rm -rf "$REPO/soak-bulk"
    fi
    if (( i % 7 == 0 )); then g stash -q --include-untracked; g checkout -q soak-side; g checkout -q -; g stash pop -q; fi
    sleep 0.3
  done
) &
CHURN_PID=$!

OUT="$WORK/leaks.txt"
# MallocStackLogging=lite (set by -atExit) records where each leaked block was allocated.
leaks -quiet -atExit -- "$APP" --soak "$ROUNDS" "$REPO" > "$OUT" 2>&1
STATUS=$?

grep '^SOAK ' "$OUT"
case "$STATUS" in
  0) echo "LEAKS none ($(grep -m1 -o '[0-9]* leaks for [0-9]* total leaked bytes' "$OUT" || echo '0 leaks'))" ;;
  1) grep -v '^SOAK ' "$OUT"; echo "LEAKS FOUND"; ;;
  *) cat "$OUT"; echo "LEAKS error (leaks exited with $STATUS)" ;;
esac
exit $(( STATUS > 1 ? 2 : STATUS ))
