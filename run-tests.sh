#!/usr/bin/env bash
# Compile and run every example, diffing against tests/<name>.expected
set -u
cd "$(dirname "$0")"
nim c --hints:off --warnings:off -o:bin/clonim src/clonim.nim || exit 1
fail=0
for f in examples/*.clj; do
  name=$(basename "$f" .clj)
  exp="tests/$name.expected"
  [ -f "$exp" ] || continue
  got=$(./bin/clonim run "$f" 2>&1)
  if [ "$got" = "$(cat "$exp")" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name"; diff <(echo "$got") "$exp" | head -20; fail=1
  fi
done
exit $fail
