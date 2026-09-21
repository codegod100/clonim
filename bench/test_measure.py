import contextlib
import io
import json
import os

import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import measure
from store import validate_results


class MeasureTests(unittest.TestCase):
    def test_json_matches_storage_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "result.json"
            with patch.dict(os.environ, BENCH_JSON=str(output)), \
                    patch.object(measure.subprocess, "run") as run, \
                    patch.object(measure.time, "perf_counter", side_effect=range(176)), \
                    contextlib.redirect_stdout(io.StringIO()):
                measure.main(["--with-jolt"])
            results = json.loads(output.read_text())
            validate_results(results)
            self.assertEqual(set(results["best_ms"]), {"clonim", "jolt"})
            self.assertEqual(run.call_count, 96)
            self.assertTrue(all(call.kwargs["check"] for call in run.call_args_list))

    def test_failed_binary_aborts(self):
        with patch.object(measure.subprocess, "run",
                          side_effect=subprocess.CalledProcessError(1, "bench")), \
                self.assertRaises(subprocess.CalledProcessError):
            measure.timed(["bench"])


if __name__ == "__main__":
    unittest.main()
