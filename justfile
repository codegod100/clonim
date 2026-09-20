# clonim — a Clojure compiler hosted on Nim

bin := "bin/clonim"

# Build the compiler
build:
    nim c --hints:off --warnings:off -o:{{bin}} src/clonim.nim

# Build with optimisations on (compiler and, via -d:release, the programs it emits)
release:
    nim c -d:release --hints:off --warnings:off -o:{{bin}} src/clonim.nim

# Run every example against tests/<name>.expected
test: build
    ./run-tests.sh

# Compile and run a .clj file, e.g. `just run examples/tour.clj`
run file: build
    ./{{bin}} run {{file}}

# Emit the generated Nim for a .clj file without compiling it
emit file: build
    ./{{bin}} emit {{file}}

# Compile a .clj file to a native binary
compile file: build
    ./{{bin}} build {{file}}

# Benchmarks: persistent-collection writes, and lazy early exit
bench: release
    ./{{bin}} run examples/persistent-bench.clj -d
    ./{{bin}} run examples/lazy-bench.clj -d

# Re-record tests/<name>.expected from current output
accept: build
    #!/usr/bin/env bash
    set -euo pipefail
    for f in examples/*.clj; do
      name=$(basename "$f" .clj)
      [ -f "tests/$name.expected" ] || continue
      ./{{bin}} run "$f" > "tests/$name.expected" 2>&1
      echo "recorded $name"
    done

# Remove build output
clean:
    rm -rf bin nimcache
