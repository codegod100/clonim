#!/bin/sh
# Build the release REPL host that the release compiler ships beside itself:
# packaging/build-repl-host.sh <out>
#
# The host holds the runtime for a whole `clonim repl` session and loads each
# input as a shared library; see src/repl_host.nim and src/repl/nimbase.h.
# It must be built in release mode, like the programs the release compiler
# produces, so that the libraries it loads agree with it on Nim's ABI.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$(dirname -- "$1")"
out=$(CDPATH= cd -- "$(dirname -- "$1")" && pwd)/$(basename -- "$1")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

nim c -d:release -d:ssl --hints:off --warnings:off \
  --passC:-I"$root/src/repl" --passL:-rdynamic \
  --nimcache:"$work/nimcache" -o:"$out" "$root/src/repl_host.nim"
