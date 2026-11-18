#!/bin/bash
# Launches the real app in benchmark mode against two throwaway repos and checks launch time and memory.
#
#   scripts/perf-app.sh
#
# Each launch opens a window for a moment (expected). Numbers are the median of RUNS launches.
# Exits non-zero when a budget is missed or a launch fails.
set -uo pipefail
cd "$(dirname "$0")/.."

RUNS=5
TIMEOUT=20 # seconds per launch; a hung launch counts as a failure

# Budgets: first_snapshot_ms, file_open_ms, footprint_mb (demo repo, then large repo).
DEMO_BUDGET=(200 300 55)
LARGE_BUDGET=(250 350 60)

swift build -c release >/dev/null || { echo "build failed" >&2; exit 2; }
BIN="$PWD/.build/release/MicroDiff"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/microdiff-perf.XXXXXX")" || exit 2
# ${WORK:?} aborts instead of ever expanding to "/" if the variable were empty.
trap 'rm -rf "${WORK:?}"' EXIT

# Same isolation as make-demo-repo.sh: never read or write the user's git config, never sign.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
g() { git -c user.name=Perf -c user.email=perf@example.com -c commit.gpgsign=false -c init.defaultBranch=main "$@"; }

DEMO="$(scripts/make-demo-repo.sh "$WORK/demo")" || exit 2

# Large repo: 2,000 tracked files in 100 folders, then 150 modified and 50 untracked.
LARGE="$WORK/large"
mkdir -p "$LARGE"
g -C "$LARGE" init -q
for i in $(seq 0 1999); do
  d="$LARGE/dir$((i % 100))"
  mkdir -p "$d"
  printf 'line one\nline two %s\nline three\n' "$i" > "$d/file$i.txt"
done
g -C "$LARGE" add -A
g -C "$LARGE" commit -q -m "initial"
for i in $(seq 0 149); do
  printf 'line one\nline two changed %s\nline three\nline four\n' "$i" > "$LARGE/dir$((i % 100))/file$i.txt"
done
mkdir -p "$LARGE/untracked"
for i in $(seq 0 49); do echo "new $i" > "$LARGE/untracked/new$i.txt"; done

# One launch: prints the JSON line, or nothing when the app fails or hangs.
launch() {
  local out="$WORK/out.$$"
  "$BIN" "$1" --bench > "$out" 2>/dev/null &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if (( waited >= TIMEOUT * 10 )); then kill -9 "$pid" 2>/dev/null; break; fi
    sleep 0.1
    waited=$((waited + 1))
  done
  wait "$pid" 2>/dev/null
  grep -m1 '^{' "$out"
}

# Median of the numbers on stdin (one per line).
median() { python3 -c 'import sys; v = sorted(map(float, sys.stdin.read().split())); print(f"{v[len(v) // 2]:.1f}")'; }

# field <name> reads one number out of the JSON line on stdin.
field() { python3 -c 'import sys, json; print(json.loads(sys.stdin.read())[sys.argv[1]])' "$1"; }

failed=0
printf '%-8s %-15s %9s %9s  %s\n' repo metric median budget result

check() { # repo metric samples budget
  local value
  value="$(echo "$3" | median)"
  local ok=OK
  if ! python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) <= float(sys.argv[2]) else 1)' "$value" "$4"; then ok=FAIL; failed=1; fi
  printf '%-8s %-15s %9s %9s  %s\n' "$1" "$2" "$value" "$4" "$ok"
}

run_repo() { # name path budget...
  local name=$1 path=$2; shift 2
  local budget=("$@") snaps="" opens="" mbs="" changes="" ok=0 line
  for _ in $(seq "$RUNS"); do
    if line="$(launch "$path")" && [[ -n "$line" ]]; then
      snaps+="$(echo "$line" | field first_snapshot_ms)"$'\n'
      opens+="$(echo "$line" | field file_open_ms)"$'\n'
      mbs+="$(echo "$line" | field footprint_mb)"$'\n'
      changes="$(echo "$line" | field changes)"
      ok=$((ok + 1))
    else
      echo "$name: launch failed or timed out after ${TIMEOUT}s" >&2
      failed=1
    fi
  done
  if (( ok == 0 )); then return; fi
  check "$name" first_snapshot_ms "$snaps" "${budget[0]}"
  check "$name" file_open_ms "$opens" "${budget[1]}"
  check "$name" footprint_mb "$mbs" "${budget[2]}"
  printf '%-8s %-15s %9s\n' "$name" changes "$changes"
}

run_repo demo "$DEMO" "${DEMO_BUDGET[@]}"
run_repo large "$LARGE" "${LARGE_BUDGET[@]}"

if (( failed )); then echo "perf-app: FAILED"; exit 1; fi
echo "perf-app: all budgets met"
