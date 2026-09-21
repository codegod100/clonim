#!/usr/bin/env python3
"""Time clonim's benchmark binaries, optionally against jolt.

Two things make these numbers trustworthy rather than merely small:

  * best-of-N, not mean. A benchmark process contends with whatever else the
    machine is doing; contention only ever adds time, so the minimum is the
    cleanest estimate of the work itself.
  * round-robin, not grouped. Running every binary once per round, rather than
    one binary N times before moving on, means a slow stretch of machine time
    lands on all of them instead of whichever happened to be running.

Compute is reported as total minus the `hello` time for the same toolchain,
which is how a 0.5 ms native start is kept from flattering clonim against a
runtime that pays ~105 ms to boot before it reaches main.
"""
import collections, subprocess, sys, time

BENCHES = ["fib", "loop", "seqs"]
ROUNDS = 11


def timed(cmd):
    start = time.perf_counter()
    subprocess.run(cmd, capture_output=True)
    return (time.perf_counter() - start) * 1000


def main(argv):
    # {label: {bench: argv}} -- "hello" is the startup probe every label needs.
    suites = {"clonim": {b: [f"bench/bin/{b}"] for b in ["hello"] + BENCHES}}
    if "--with-jolt" in argv:
        suites["jolt"] = {b: [f"bench/bin/jolt-{b}"] for b in ["hello"] + BENCHES}

    best = collections.defaultdict(lambda: float("inf"))
    for label, cmds in suites.items():          # warm the page cache first
        for cmd in cmds.values():
            subprocess.run(cmd, capture_output=True)
    for _ in range(ROUNDS):
        for label, cmds in suites.items():
            for bench, cmd in cmds.items():
                best[label, bench] = min(best[label, bench], timed(cmd))

    width = max(len(l) for l in suites)
    print(f"{'':<{width}} {'startup':>9} " + " ".join(f"{b:>8}" for b in BENCHES))
    for label in suites:
        start = best[label, "hello"]
        row = " ".join(f"{best[label, b] - start:8.0f}" for b in BENCHES)
        print(f"{label:<{width}} {start:8.1f}ms {row}")
    print("\nstartup is total wall clock; the rest is compute, startup subtracted.")


if __name__ == "__main__":
    main(sys.argv[1:])
