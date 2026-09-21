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
    rm -rf bin nimcache bench/bin

# ---------------------------------------------------------------- benchmarks
#
# `just bench` above stays as it was: the two feature benchmarks, run through
# the compiler with timing printed by the programs themselves. What follows
# times whole processes instead, which is the only way to see startup, and can
# put another Clojure toolchain beside clonim.

# `just measure jolt` also builds and times the same programs under jolt, if it
# is installed. Both toolchains get a `hello` binary so startup can be
# subtracted; see bench/measure.py for why the numbers are best-of-N
# round-robin rather than averaged.
# Record a Jolt comparison, flag regressions, and commit only its history record.
bench-store threshold="10":
    python3 bench/store.py {{quote(threshold)}}

# Time bench/*.clj as native binaries, optionally against jolt.
measure mode="solo": release
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p bench/bin
    for f in bench/*.clj; do
        name=$(basename "$f" .clj)
        ./{{bin}} build "$f" -o "bench/bin/$name" >/dev/null
    done
    if [ "{{mode}}" != "jolt" ]; then
        exec python3 bench/measure.py
    fi
    if ! command -v jolt >/dev/null; then
        if [ -n "${BENCH_JSON:-}" ]; then
            echo "jolt is required when storing benchmark results" >&2
            exit 1
        fi
        echo "jolt is not installed; running clonim only" >&2
        exec python3 bench/measure.py
    fi
    # jolt builds a namespace, not a file, so mirror each bench into a deps.edn
    # project under a throwaway directory, wrapping the last form in a -main.
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    mkdir -p "$work/src"
    echo '{:paths ["src"]}' > "$work/deps.edn"
    for f in bench/*.clj; do
        name=$(basename "$f" .clj)
        { echo "(ns b$name)"
          sed 's/^(println \(.*\))$/(defn -main [\& _] (println \1))/' "$f"
        } > "$work/src/b$name.clj"
        (cd "$work" && jolt build -m "b$name" -o "b$name" --opt >/dev/null)
        cp "$work/b$name" "bench/bin/jolt-$name"
    done
    python3 bench/measure.py --with-jolt
