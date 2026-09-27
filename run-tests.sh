#!/usr/bin/env bash
# Compile and run every example, diffing against tests/<name>.expected
#
#   ./run-tests.sh                      # build bin/clonim from source first
#   CLONIM=bin/clonim ./run-tests.sh    # test an already built compiler
set -u
cd "$(dirname "$0")"
clonim="${CLONIM:-}"
if [ -z "$clonim" ]; then
  nim c --hints:off --warnings:off -o:bin/clonim src/clonim.nim || exit 1
  clonim=./bin/clonim
fi
fail=0
for f in examples/*.clj; do
  name=$(basename "$f" .clj)
  exp="tests/$name.expected"
  [ -f "$exp" ] || continue
  got=$("$clonim" run "$f" 2>&1)
  if [ "$got" = "$(cat "$exp")" ]; then
    echo "ok   $name"
  else
    got_file=$(mktemp)
    printf '%s\n' "$got" > "$got_file"
    echo "FAIL $name"
    diff -u "$exp" "$got_file" | head -20
    rm -f "$got_file"
    fail=1
  fi
done
exit $fail
