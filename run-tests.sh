#!/usr/bin/env bash
# Compile and run every example, diffing against tests/<name>.expected
#
#   ./run-tests.sh                      # build bin/clonim from source first
#   CLONIM=bin/clonim ./run-tests.sh    # test an already built compiler
#   JOBS=1 ./run-tests.sh               # run examples one at a time
#
# Examples are independent, so they build and run in parallel (JOBS defaults
# to the CPU count). Each build is dominated by one single-threaded C compile
# of the runtime, so running several at once is what keeps the suite fast.
set -u
cd "$(dirname "$0")"
clonim="${CLONIM:-}"
if [ -z "$clonim" ]; then
  nim c --hints:off --warnings:off -o:bin/clonim src/clonim.nim || exit 1
  clonim=./bin/clonim
fi
jobs="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

# Writes "ok" or "FAIL" plus a diff to $out/<name>.
check() {
  local name=$1 f=$2 exp="tests/$1.expected" got
  got=$("$clonim" run "$f" 2>&1)
  if [ "$got" = "$(cat "$exp")" ]; then
    echo "ok   $name" > "$out/$name"
  else
    printf '%s\n' "$got" > "$out/$name.got"
    { echo "FAIL $name"
      diff -u "$exp" "$out/$name.got" | head -20
    } > "$out/$name"
  fi
}

names=()
for f in examples/*.clj; do
  name=$(basename "$f" .clj)
  [ -f "tests/$name.expected" ] || continue
  # examples/postgres.clj needs a server to talk to
  if [ "$name" = postgres ] && [ -z "${CLONIM_TEST_POSTGRES:-}" ]; then
    echo "skip postgres (set CLONIM_TEST_POSTGRES to a connection URI to run it)"
    continue
  fi
  names+=("$name")
done

# The first example runs alone: from a source checkout it builds the private
# runtime archive, which concurrent first runs would race to create. (The
# release compiler locks its shared runtime cache itself.)
running=0
for i in "${!names[@]}"; do
  name=${names[$i]}
  if [ "$i" -eq 0 ]; then
    check "$name" "examples/$name.clj"
    continue
  fi
  check "$name" "examples/$name.clj" &
  running=$((running + 1))
  if [ "$running" -ge "$jobs" ]; then
    wait -n
    running=$((running - 1))
  fi
done
wait

fail=0
for name in "${names[@]}"; do
  cat "$out/$name"
  grep -q '^ok ' "$out/$name" || fail=1
done

# The REPL runs each input once in a long-lived host, so this checks what a
# session keeps between inputs rather than a program's output.
got=$("$clonim" repl < tests/repl_session.clj 2>&1)
if [ "$got" = "$(cat tests/repl_session.expected)" ]; then
  echo "ok   repl_session"
else
  echo "FAIL repl_session"
  diff -u tests/repl_session.expected <(printf '%s\n' "$got") | head -20
  fail=1
fi
exit $fail
