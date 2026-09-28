#!/bin/sh
# Build the release runtime archive that the release compiler links programs
# against: packaging/build-runtime.sh <out.a>
#
# Nim compiles its system module into both the archive and every program, so
# the two define many of the same symbols. Zig's linker has no
# --allow-multiple-definition, so the archive's definitions are made weak
# instead: the program's own copy wins, and the archive fills in the rest.
# Only defined symbols are weakened; a weak undefined reference would not pull
# in the archive member that defines it and would resolve to null.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$(dirname -- "$1")"
out=$(CDPATH= cd -- "$(dirname -- "$1")" && pwd)/$(basename -- "$1")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

nim c -d:release -d:ssl --app:staticlib --nimMainPrefix:ClonimRuntime \
  --hints:off --warnings:off \
  --passC:-ffunction-sections --passC:-fdata-sections \
  --nimcache:"$work/nimcache" -o:"$work/runtime.a" "$root/src/runtime_lib.nim"

mkdir "$work/objs"
cd "$work/objs"
ar x "$work/runtime.a"
for obj in *.o; do
  nm --defined-only --extern-only "$obj" | awk '{ print $3 }' > "$work/syms"
  # objcopy fails on an empty list, and such objects export nothing anyway.
  if [ -s "$work/syms" ]; then
    objcopy --weaken-symbols="$work/syms" "$obj"
  fi
done
rm -f "$out"
ar rcs "$out" *.o
