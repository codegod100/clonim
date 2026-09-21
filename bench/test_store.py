"""Stdlib tests; git and benchmark execution are mocked, never committed."""

import copy
import importlib.util
import json

import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("bench_store", Path(__file__).with_name("store.py"))
assert spec is not None and spec.loader is not None
store = importlib.util.module_from_spec(spec)
spec.loader.exec_module(store)


def results(value=10):
    best = {label: {bench: value for bench in store.BENCHES} for label in store.LABELS}
    return {
        "schema_version": 1, "rounds": 11,
        "samples_ms": {label: {bench: [value] * 11 for bench in store.BENCHES}
                       for label in store.LABELS},
        "best_ms": best,
        "compute_ms": {label: {bench: 0 for bench in store.BENCHES}
                       for label in store.LABELS},
    }


def record(value=10, compatible=None, date="2026-01-01T00:00:00+00:00"):
    return {"schema_version": 1, "created_at": date,
            "source_revision": "old", "compatibility": compatible or {"machine": "a"},
            "results": results(value)}


class ComparisonTests(unittest.TestCase):
    def test_no_baseline(self):
        comparison = store.compare(results(), None, 10)
        self.assertFalse(comparison["regression"])
        self.assertEqual(comparison["deltas"], {})

    def test_strict_threshold_and_all_benches(self):
        baseline = ("prior.json", record())
        self.assertFalse(store.compare(results(11), baseline, 10)["regression"])
        self.assertFalse(store.compare(results(9), baseline, 10)["regression"])
        for bench in store.BENCHES:
            current = results()
            current["best_ms"]["clonim"][bench] = 12
            comparison = store.compare(current, baseline, 10)
            self.assertTrue(comparison["regression"])
            self.assertEqual(comparison["deltas"][bench]["percent"], 20)
        current = results()
        current["best_ms"]["jolt"]["fib"] = 100
        self.assertFalse(store.compare(current, baseline, 10)["regression"])

    def test_zero_baseline_is_json_safe(self):
        comparison = store.compare(results(1), ("zero.json", record(0)), 10)
        self.assertTrue(comparison["regression"])
        self.assertIsNone(comparison["deltas"]["hello"]["percent"])
        json.dumps(comparison, allow_nan=False)
        self.assertFalse(store.compare(results(0), ("zero", record(0)), 10)["regression"])

    def test_latest_compatible_not_source_revision_or_filename(self):
        with tempfile.TemporaryDirectory() as work:
            directory = Path(work)
            old = record()
            latest = record(date="2026-02-01T00:00:00+00:00")
            latest["source_revision"] = "different"
            incompatible = record(compatible={"machine": "b"},
                                  date="2026-03-01T00:00:00+00:00")
            for name, data in (("z.json", old), ("a.json", latest),
                               ("new.json", incompatible)):
                (directory / name).write_text(json.dumps(data))
            (directory / "broken.json").write_text("{")
            self.assertEqual(store.latest_baseline(directory, old["compatibility"])[0],
                             "a.json")
            self.assertIsNone(store.latest_baseline(directory, {"machine": "c"}))
            # Every compatibility component matters, not just machine identity.
            for key in ("tool_versions", "methodology", "sha256"):
                changed = dict(old["compatibility"], **{key: "changed"})
                self.assertIsNone(store.latest_baseline(directory, changed))

    def test_validation(self):
        store.validate_results(results())
        mutations = [lambda r: r.update(rounds=10),
                     lambda r: r["best_ms"].pop("jolt"),
                     lambda r: r["samples_ms"]["clonim"].update(hello=[1]),
                     lambda r: r["best_ms"]["clonim"].update(fib=float("nan")),
                     lambda r: r["compute_ms"]["clonim"].update(fib=1)]
        for mutate in mutations:
            data = copy.deepcopy(results())
            mutate(data)
            with self.assertRaises(ValueError):
                store.validate_results(data)

    def test_non_object_measurement_raises_value_error(self):
        for value in (None, [], "invalid", 1, True):
            with self.subTest(value=value), self.assertRaisesRegex(
                ValueError, "measurement must be a JSON object"
            ):
                store.validate_results(value)

    def test_threshold(self):
        self.assertEqual(store.threshold_value("10"), 10)
        for text in ("-1", "nan", "inf"):
            with self.assertRaises(store.argparse.ArgumentTypeError):
                store.threshold_value(text)


class WorkflowTests(unittest.TestCase):
    def test_dirty_tree_including_untracked(self):
        for status in (" M source.nim", "?? new.txt", "A  staged.txt"):
            with patch.object(store, "command", return_value=status) as command:
                with self.assertRaisesRegex(ValueError, "clean"):
                    store.require_clean(Path("."))
                self.assertIn("--untracked-files=all", command.call_args.args)

    def test_missing_jolt_before_measurement(self):
        with patch.object(store, "require_clean"), \
                patch.object(store.shutil, "which", return_value=None), \
                patch.object(store.subprocess, "run") as run:
            with self.assertRaisesRegex(ValueError, "jolt"):
                store.store(Path("."), 10)
            run.assert_not_called()

    def workflow(self, root, value=10, failure=None):
        compatible = {"machine": "a"}

        def run(args, **kwargs):
            if args == ["just", "measure", "jolt"]:
                path = Path(kwargs["env"]["BENCH_JSON"])
                self.assertTrue(path.is_absolute())
                self.assertEqual(kwargs["cwd"], root)
                if failure == "measure":
                    raise subprocess.CalledProcessError(1, args)
                if failure == "missing":
                    return
                path.write_text("{}" if failure == "invalid" else json.dumps(results(value)))
            elif args[:2] == ["git", "commit"] and failure == "commit":
                raise subprocess.CalledProcessError(1, args)

        with patch.object(store, "require_clean"), \
                patch.object(store.shutil, "which", return_value="/tool"), \
                patch.object(store, "command", return_value="source-sha"), \
                patch.object(store, "compatibility", return_value=compatible), \
                patch.object(store.subprocess, "run", side_effect=run) as runner:
            if failure:
                with self.assertRaises((OSError, ValueError, subprocess.CalledProcessError)):
                    store.store(root, 10)
                return runner
            self.assertEqual(store.store(root, 10), 1 if value > 11 else 0)
            return runner

    def test_regression_recorded_then_committed_only_its_path(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            directory = root / "bench/results"
            directory.mkdir(parents=True)
            (directory / "prior.json").write_text(json.dumps(record()))
            runner = self.workflow(root, 12)
            paths = [p for p in directory.glob("*.json") if p.name != "prior.json"]
            self.assertEqual(len(paths), 1)
            data = json.loads(paths[0].read_text())
            self.assertEqual(data["source_revision"], "source-sha")
            self.assertTrue(data["comparison"]["regression"])
            relative = str(paths[0].relative_to(root))
            add, commit = runner.call_args_list[-2:]
            self.assertEqual(add.args[0], ["git", "add", "--", relative])
            self.assertEqual(commit.args[0][:3], ["git", "commit", "--only"])
            self.assertEqual(commit.args[0][-2:], ["--", relative])
            self.assertEqual(commit.kwargs["env"]["GIT_EDITOR"], "true")

    def test_failed_measurement_creates_no_record(self):
        for failure in ("measure", "missing", "invalid"):
            with tempfile.TemporaryDirectory() as work:
                root = Path(work)
                runner = self.workflow(root, failure=failure)
                self.assertFalse((root / "bench/results").exists())
                self.assertEqual(runner.call_count, 1)

    def test_commit_failure_keeps_record(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            self.workflow(root, failure="commit")
            self.assertEqual(len(list((root / "bench/results").glob("*.json"))), 1)

    def test_unique_records(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            self.workflow(root)
            self.workflow(root)
            self.assertEqual(len(list((root / "bench/results").glob("*.json"))), 2)


if __name__ == "__main__":
    unittest.main()
