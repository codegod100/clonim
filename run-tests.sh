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
    got_file=$(mktemp)
    printf '%s\n' "$got" > "$got_file"
    echo "FAIL $name"
    diff -u "$exp" "$got_file" | head -20
    rm -f "$got_file"
    fail=1
  fi
done
exit $fail
