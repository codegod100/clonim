
"""Record and commit a benchmark run; exit 1 after committing a regression."""

import argparse
import hashlib
import json
import math
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BENCHES = ("hello", "fib", "loop", "seqs")
LABELS = ("clonim", "jolt")


def command(root, *args, env=None):
    return subprocess.check_output(args, cwd=root, env=env, text=True).strip()


def require_clean(root):
    if command(root, "git", "status", "--porcelain", "--untracked-files=all"):
        raise ValueError("working tree must be clean, including untracked files")


def cpu_info():
    try:
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            key, sep, value = line.partition(":")
            if sep and key.strip() in ("model name", "Hardware"):
                return value.strip()
    except OSError:
        pass
    return platform.processor() or "unknown"


def compatibility(root):
    paths = sorted((root / "bench").glob("*.clj"))
    paths += [root / "bench/measure.py", root / "justfile"]
    return {
        "machine": {
            "system": platform.system(),
            "release": platform.release(),
            "machine": platform.machine(),
            "hostname": platform.node(),
            "cpu": cpu_info(),
            "logical_cpus": os.cpu_count(),
        },
        "tool_versions": {
            tool: command(root, tool, "--version") for tool in ("nim", "jolt")
        },
        "methodology": {
            "schema_version": 1,
            "rounds": 11,
            "metric": "best_ms",
            "schedule": "round-robin",
        },
        "sha256": {
            str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in paths
        },
    }


def number(value):
    return type(value) in (int, float) and math.isfinite(value)


def validate_results(results):
    if not isinstance(results, dict):
        # Invalid JSON measurements consistently raise ValueError for callers.
        raise ValueError("measurement must be a JSON object")  # noqa: TRY004
    if results.get("schema_version") != 1 or results.get("rounds") != 11:
        raise ValueError("expected measurement schema_version=1 and rounds=11")
    try:
        for label in LABELS:
            for bench in BENCHES:
                samples = results["samples_ms"][label][bench]
                best = results["best_ms"][label][bench]
                if (not isinstance(samples, list) or len(samples) != 11
                        or not all(number(v) and v >= 0 for v in samples)
                        or not number(best) or best != min(samples)):
                    raise ValueError(f"invalid samples/best for {label}/{bench}")
                # Some producers omit the identically-zero hello compute metric.
                if bench != "hello" or bench in results["compute_ms"][label]:
                    compute = results["compute_ms"][label][bench]
                    expected = best - results["best_ms"][label]["hello"]
                    if not number(compute) or not math.isclose(
                            compute, expected, rel_tol=1e-9, abs_tol=1e-9):
                        raise ValueError(f"invalid compute for {label}/{bench}")
    except (KeyError, TypeError) as exc:
        raise ValueError("missing or invalid measurement metrics") from exc


def latest_baseline(directory, compatible):
    candidates = []
    for path in directory.glob("*.json"):
        try:
            record = json.loads(path.read_text())
            if record["schema_version"] != 1 or record["compatibility"] != compatible:
                continue
            validate_results(record["results"])
            created = datetime.fromisoformat(record["created_at"])
            if created.utcoffset() is None:
                continue
            candidates.append((created, path.name, record))
        except (OSError, ValueError, KeyError, TypeError):
            continue
    if not candidates:
        return None
    _, name, record = max(candidates, key=lambda item: (item[0], item[1]))
    return name, record


def compare(results, baseline, threshold):
    comparison = {"baseline": None, "threshold_percent": threshold,
                  "deltas": {}, "regression": False}
    if baseline is None:
        return comparison
    name, prior = baseline
    comparison["baseline"] = name
    for bench in BENCHES:
        old = prior["results"]["best_ms"]["clonim"][bench]
        new = results["best_ms"]["clonim"][bench]
        delta = new - old
        percent = 100 * delta / old if old else (0.0 if new == 0 else None)
        regression = delta > old * threshold / 100
        comparison["deltas"][bench] = {
            "baseline_ms": old, "current_ms": new, "delta_ms": delta,
            "percent": percent, "regression": regression,
        }
        comparison["regression"] |= regression
    return comparison


def report(comparison):
    if comparison["baseline"] is None:
        print("No compatible baseline; recording initial run.")
    else:
        print(f"Baseline: {comparison['baseline']}")
        for bench, delta in comparison["deltas"].items():
            percent = delta["percent"]
            change = f"{percent:+.2f}%" if percent is not None else "increase from zero"
            print(f"  {bench}: {delta['delta_ms']:+.3f} ms ({change})"
                  + (" REGRESSION" if delta["regression"] else ""))
    print(f"Regression: {comparison['regression']}")


def store(root, threshold):
    require_clean(root)
    for tool in ("jolt", "nim", "just"):
        if shutil.which(tool) is None:
            raise ValueError(f"required executable not found: {tool}")
    revision = command(root, "git", "rev-parse", "HEAD")
    compatible = compatibility(root)
    directory = root / "bench/results"
    baseline = latest_baseline(directory, compatible)
    with tempfile.TemporaryDirectory(prefix="clonim-bench-") as work:
        output = Path(work).resolve() / "measurement.json"
        env = dict(os.environ, BENCH_JSON=str(output))
        subprocess.run(["just", "measure", "jolt"], cwd=root, env=env, check=True)
        results = json.loads(output.read_text())
        validate_results(results)
    if command(root, "git", "rev-parse", "HEAD") != revision:
        raise ValueError("HEAD changed during measurement; refusing to record")
    if compatibility(root) != compatible:
        raise ValueError("benchmark inputs or environment changed during measurement")
    comparison = compare(results, baseline, threshold)
    now = datetime.now(timezone.utc)
    record = {
        "schema_version": 1,
        "created_at": now.isoformat(),
        "source_revision": revision,
        "compatibility": compatible,
        "results": results,
        "comparison": comparison,
    }
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / f"{now.strftime('%Y%m%dT%H%M%S.%fZ')}-{uuid.uuid4().hex}.json"
    with path.open("x") as stream:
        json.dump(record, stream, indent=2, allow_nan=False)
        stream.write("\n")
    relative = str(path.relative_to(root))
    report(comparison)
    print(f"Record: {relative}", flush=True)
    subprocess.run(["git", "add", "--", relative], cwd=root, check=True)
    # --only excludes anything another process staged while benchmarks ran.
    subprocess.run(["git", "commit", "--only", "-m", f"bench: record {path.stem}",
                    "--", relative], cwd=root,
                   env=dict(os.environ, GIT_EDITOR="true"), check=True)
    return 1 if comparison["regression"] else 0


def threshold_value(text):
    value = float(text)
    if not math.isfinite(value) or value < 0:
        raise argparse.ArgumentTypeError("threshold must be finite and nonnegative")
    return value


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("threshold", nargs="?", type=threshold_value, default=10.0,
                        help="alert above this percentage increase (default: 10)")
    args = parser.parse_args(argv)
    try:
        return store(ROOT, args.threshold)
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(f"bench-store: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
