# Stored benchmarks

`just bench-store` invokes `python3 bench/store.py`, with an optional percentage
threshold (default **10**):

```sh
just bench-store
just bench-store 15
# Equivalent direct invocation:
python3 bench/store.py 15
```

The task builds release binaries for clonim and jolt-lang using the existing
`measure jolt` recipe. Recording uses only Python's standard library.

## Requirements and recording

- Start with a **clean Git working tree and index, including untracked files**.
  Commit, stash, or remove outstanding work yourself first. Ignored build output
  does not count as dirty.
- `git`, `just`, `nim`, and `jolt` must be available on `PATH`. Missing jolt is an
  error, not permission to fall back to a clonim-only run.
- Run on an otherwise idle machine. Do not edit compiler sources or run another
  benchmark/recording process concurrently.

The script invokes `just measure jolt` from the repository root, setting
`BENCH_JSON` to an absolute path in a temporary directory. The producer must write
JSON with `schema_version: 1`, `rounds: 11`, and `samples_ms`, `best_ms`, and
`compute_ms` mappings keyed by tool (`clonim`, `jolt`) then benchmark (`hello`,
`fib`, `loop`, `seqs`). Each raw sample array has 11 nonnegative millisecond
values, `best_ms` is its minimum, and `compute_ms` is best minus that tool's hello
best. The identically-zero hello compute entry may be omitted. Missing, failed,
or malformed measurements are not recorded.

A unique UTC timestamp plus UUID names each `bench/results/*.json` record. It
contains the raw results, the source Git revision, machine/OS/hostname/CPU
information, full `nim --version` and `jolt --version` output, SHA-256 hashes of
all `bench/*.clj`, `bench/measure.py`, and `justfile`, and the baseline comparison.
Hashing `justfile` also captures changes to the benchmark build commands.

The newest compatible valid record by UTC creation time is the baseline.
Compatibility requires identical machine information, tool versions, methodology,
and input hashes; **source revision is deliberately not a compatibility key**,
so compiler changes can be compared. Malformed and incompatible records are
skipped. With no compatible baseline, the run establishes one without an alert.

## Metrics and exit status

Regression checks use clonim's **best total wall-clock milliseconds**, including
`hello` startup, independently for all four benchmarks. An increase **strictly
greater than** the threshold flags a regression. Jolt results and startup-adjusted
compute times are retained for context, not used to trigger alerts. The report
and record contain absolute and percentage deltas and a regression flag. If a
baseline is zero, any positive value is a regression and its undefined percentage
is stored as JSON `null` (zero to zero is 0%).

These are noisy performance alerts, not statistical significance tests.
Best-of-11 reduces scheduling interference but cannot remove thermal, frequency,
background-load, or toolchain variability. Confirm unexpected changes with
additional runs before drawing conclusions. A recorded regression can itself
become the next baseline; comparisons are to the latest run, not a fixed target.

After writing the record, the script stages **only that new file** and runs
`git commit --only -m ... -- path` with `GIT_EDITOR=true`. Unrelated changes that
appear during the run are neither staged nor included by the script; unrelated
index entries are preserved. Git hooks still run normally. The original clean
HEAD is stored as `source_revision`, not the subsequent record commit. A changed
HEAD or changed benchmark inputs/environment during measurement aborts recording.
Concurrent compiler-source edits are unsupported: the initial clean-tree check
is not a filesystem snapshot.

Exit codes:

- **0**: record committed, no regression (or no compatible baseline).
- **1**: regression **recorded and committed first**, then reported as failure.
- **2**: precondition, measurement, validation, or Git failure. If staging or
  committing fails, the JSON file remains for inspection/recovery; the script
  does not reset, delete, or roll back unrelated work. Resolve the Git failure
  and commit the retained record explicitly before retrying.

The record commit provides an auditable link to measured source; it does not
claim reproducible timings across machines or capture every external dependency.

## Tests

```sh
python3 -m unittest discover -s bench -p 'test_store.py' -v
```

Tests use temporary directories and mock benchmark/Git execution; they never run
real benchmarks or create real commits.
