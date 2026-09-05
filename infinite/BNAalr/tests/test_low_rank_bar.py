#!/usr/bin/env python3
import copy
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import low_rank_bar as solver  # noqa: E402


class LowRankBARTests(unittest.TestCase):
    def test_one_dimensional_exact_exponential(self):
        result = solver.solve({
            "drift": [-1.0], "covariance": [[2.0]], "reflection": [[1.0]],
            "options": {"max_rank": 4, "bar_tolerance": 1e-10},
        })
        self.assertTrue(result["converged"])
        self.assertTrue(result["diagnostics"]["exact_product_form_detected"])
        self.assertEqual(result["mixture"]["rank"], 1)
        self.assertAlmostEqual(result["stationary_means"][0], 1.0, places=11)
        self.assertAlmostEqual(result["stationary_variances"][0], 1.0, places=11)
        self.assertLess(result["diagnostics"]["validation_relative_bar_rms"], 1e-11)

    def test_independent_two_dimensional_case(self):
        result = solver.solve({
            "drift": [-1.0, -2.0],
            "covariance": [[2.0, 0.0], [0.0, 2.0]],
            "reflection": [[1.0, 0.0], [0.0, 1.0]],
        })
        self.assertEqual(result["mixture"]["rank"], 1)
        self.assertAlmostEqual(result["stationary_means"][0], 1.0, places=11)
        self.assertAlmostEqual(result["stationary_means"][1], 0.5, places=11)

    def test_oblique_skew_symmetric_fixture(self):
        result = solver.solve({
            "drift": [-0.84, -0.5],
            "covariance": [[2.0, -0.6], [-0.6, 3.0]],
            "reflection": [[1.0, -0.2], [-0.3, 1.0]],
            "options": {"bar_tolerance": 1e-9},
        })
        self.assertTrue(result["diagnostics"]["exact_product_form_detected"])
        self.assertAlmostEqual(result["stationary_means"][0], 1.0, places=10)
        self.assertAlmostEqual(result["stationary_means"][1], 1.875, places=10)
        self.assertLess(result["diagnostics"]["simplex_mass_error"], 1e-12)

    def test_non_product_refinement_is_honestly_labelled(self):
        model = json.loads((ROOT / "examples/non_product_2d.json").read_text())
        result = solver.solve(model)
        self.assertFalse(result["diagnostics"]["exact_product_form_detected"])
        self.assertIn("not a certified", result["claim"])
        history = result["diagnostics"]["refinement_history"]
        self.assertGreaterEqual(len(history), 2)
        self.assertLessEqual(
            history[-1]["validation_relative_bar_rms"],
            history[0]["validation_relative_bar_rms"] + 1e-8,
        )
        self.assertTrue(all(x > 0 and x < 100 for x in result["stationary_means"]))

    def test_near_skew_symmetric_is_not_promoted_to_exact(self):
        result = solver.solve({
            "drift": [-1.0, -1.0],
            "covariance": [[2.0, 1e-14], [1e-14, 2.0]],
            "reflection": [[1.0, 0.0], [0.0, 1.0]],
            "options": {
                "max_rank": 3,
                "bar_tolerance": 1e-4,
                "moment_tolerance": 1e-2,
            },
        })
        self.assertTrue(result["diagnostics"]["numerical_product_form_candidate"])
        self.assertFalse(result["diagnostics"]["exact_product_form_detected"])
        self.assertIn("not a certified", result["claim"])
        self.assertTrue(any("supplied decimal" in item for item in result["warnings"]))

    def test_rejects_unstable_model(self):
        with self.assertRaisesRegex(solver.ModelError, "stable class"):
            solver.solve({
                "drift": [0.1], "covariance": [[1.0]], "reflection": [[1.0]],
            })

    def test_rejects_non_psd_covariance(self):
        with self.assertRaisesRegex(solver.ModelError, "positive semidefinite"):
            solver.solve({
                "drift": [-1.0, -1.0],
                "covariance": [[1.0, 2.0], [2.0, 1.0]],
                "reflection": [[1.0, 0.0], [0.0, 1.0]],
            })

    def test_rejects_non_m_matrix_reflection(self):
        with self.assertRaisesRegex(solver.ModelError, "nonpositive off-diagonals"):
            solver.solve({
                "drift": [-1.0, -1.0],
                "covariance": [[1.0, 0.0], [0.0, 1.0]],
                "reflection": [[1.0, 0.1], [0.0, 1.0]],
            })

    def test_deterministic(self):
        model = json.loads((ROOT / "examples/non_product_2d.json").read_text())
        first = solver.solve(copy.deepcopy(model))
        second = solver.solve(copy.deepcopy(model))
        self.assertEqual(first, second)

    def test_cli_json_and_strict_exit(self):
        completed = subprocess.run(
            [sys.executable, str(ROOT / "low_rank_bar.py"),
             str(ROOT / "examples/one_dimensional.json"), "--json", "--require-tolerance"],
            check=True, text=True, capture_output=True,
        )
        payload = json.loads(completed.stdout)
        self.assertEqual(payload["schema_version"], 1)
        self.assertEqual(payload["model_layer"], "stationary orthant SRBM diffusion")

    def test_cli_failure_has_no_traceback(self):
        with tempfile.TemporaryDirectory() as directory:
            bad = pathlib.Path(directory) / "bad.json"
            bad.write_text('{"drift": [1], "covariance": [[1]], "reflection": [[1]]}')
            completed = subprocess.run(
                [sys.executable, str(ROOT / "low_rank_bar.py"), str(bad)],
                check=False, text=True, capture_output=True,
            )
        self.assertEqual(completed.returncode, 2)
        self.assertIn("stable class", completed.stderr)
        self.assertNotIn("Traceback", completed.stderr)


if __name__ == "__main__":
    unittest.main()
