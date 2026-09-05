import copy
import json
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import qbd_solver  # noqa: E402


def load_example(name):
    with (ROOT / "examples" / name).open("r", encoding="utf-8") as handle:
        return json.load(handle)


class QBDSolverTests(unittest.TestCase):
    def assertClose(self, actual, expected, tolerance=2.0e-9):
        self.assertLessEqual(abs(actual - expected), tolerance)

    def test_mm1_matches_closed_form_distribution_and_moments(self):
        result = qbd_solver.solve_document(load_example("mm1.json"))
        rho = 2.0 / 3.0

        self.assertEqual(result["status"], "ok")
        self.assertClose(result["rate_matrix"][0][0], rho)
        self.assertClose(result["stationary"]["level_0_vector"][0], 1.0 - rho)
        self.assertClose(
            result["stationary"]["level_1_vector"][0], (1.0 - rho) * rho
        )
        self.assertClose(result["queue_length"]["mean"], 2.0)
        self.assertClose(result["queue_length"]["second_moment"], 10.0)
        self.assertClose(result["queue_length"]["variance"], 6.0)

        for entry in result["level_probabilities"]:
            level = entry["level"]
            self.assertClose(entry["probability"], (1.0 - rho) * rho**level)
        for entry in result["tail_probabilities"]:
            level = entry["level_at_least"]
            self.assertClose(entry["probability"], rho**level)

        diagnostics = result["diagnostics"]
        self.assertLess(diagnostics["rate_equation_residual_inf"], 1.0e-11)
        self.assertLess(diagnostics["boundary_balance_residual_scaled"], 1.0e-11)
        self.assertLess(diagnostics["level_0_balance_residual_scaled"], 1.0e-11)
        self.assertLess(diagnostics["level_1_balance_residual_scaled"], 1.0e-11)
        self.assertLess(
            diagnostics["interior_level_2_balance_residual_scaled"], 1.0e-11
        )
        self.assertLess(diagnostics["normalization_residual"], 1.0e-13)
        self.assertLess(diagnostics["tail_identity_residual"], 1.0e-11)
        self.assertLess(diagnostics["rate_spectral_radius_upper_bound"], 1.0)
        self.assertLess(
            diagnostics["rate_spectral_radius_certificate_upper_bound"], 1.0
        )

    def test_erlang2_phase_model_matches_pollaczek_khinchine_mean(self):
        result = qbd_solver.solve_document(load_example("erlang2.json"))

        # E[S] = 2/4, E[S^2] = 6/16, rho = 1/2. The M/G/1 mean
        # customer count is rho + lambda^2 E[S^2] / (2(1-rho)) = 7/8.
        self.assertClose(result["queue_length"]["mean"], 0.875, 5.0e-9)
        self.assertClose(result["stationary"]["level_0_vector"][0], 0.5)
        phase_mass = result["stationary"]["total_interior_phase_mass"]
        self.assertClose(sum(phase_mass), 0.5)
        self.assertClose(phase_mass[0], 0.25)
        self.assertClose(phase_mass[1], 0.25)
        self.assertEqual(
            result["stability"]["classification"], "positive_recurrent"
        )
        self.assertLess(
            result["diagnostics"]["rate_equation_residual_inf"], 1.0e-11
        )
        self.assertTrue(
            all(
                value >= 0.0
                for row in result["rate_matrix"]
                for value in row
            )
        )

    def test_noncommuting_two_phase_rate_matrix_uses_row_vector_order(self):
        a_down = [[1 / 5, 1 / 20], [1 / 50, 3 / 20]]
        discrete_same = [[1341 / 2000, 0.0], [0.0, 1567 / 2000]]
        a_up = [
            [2719 / 40000, 461 / 40000],
            [443 / 40000, 1417 / 40000],
        ]
        continuous_same = [
            [discrete_same[i][j] - (1.0 if i == j else 0.0) for j in range(2)]
            for i in range(2)
        ]
        b00 = [
            [
                a_down[i][j]
                + discrete_same[i][j]
                - (1.0 if i == j else 0.0)
                for j in range(2)
            ]
            for i in range(2)
        ]
        document = {
            "boundary": {
                "level_0_same": b00,
                "level_0_up": a_up,
                "level_1_down": a_down,
                "level_1_same": continuous_same,
            },
            "interior": {
                "down": a_down,
                "same": continuous_same,
                "up": a_up,
            },
            "solver": {"max_report_level": 2, "tail_levels": [1]},
        }

        result = qbd_solver.solve_document(document)
        expected_rate = [[1 / 4, 1 / 10], [1 / 20, 1 / 5]]
        expected_pi0 = [161840 / 740800, 368900 / 740800]
        expected_pi1 = [58905 / 740800, 89964 / 740800]
        for actual_row, expected_row in zip(result["rate_matrix"], expected_rate):
            for actual, expected in zip(actual_row, expected_row):
                self.assertClose(actual, expected)
        for actual, expected in zip(
            result["stationary"]["level_0_vector"], expected_pi0
        ):
            self.assertClose(actual, expected)
        for actual, expected in zip(
            result["stationary"]["level_1_vector"], expected_pi1
        ):
            self.assertClose(actual, expected)
        self.assertClose(
            result["tail_probabilities"][0]["probability"], 10503 / 37040
        )
        self.assertClose(result["queue_length"]["mean"], 44181 / 110194)
        self.assertLess(
            result["diagnostics"]["rate_equation_residual_inf"], 1.0e-11
        )

    def test_result_is_deterministic(self):
        document = load_example("erlang2.json")
        self.assertEqual(
            qbd_solver.solve_document(copy.deepcopy(document)),
            qbd_solver.solve_document(copy.deepcopy(document)),
        )

    def test_unstable_model_is_rejected_with_drift_diagnostics(self):
        with self.assertRaises(qbd_solver.QBDStabilityError) as context:
            qbd_solver.solve_document(load_example("unstable_mm1.json"))
        stability = context.exception.details["stability"]
        self.assertEqual(stability["classification"], "transient")
        self.assertGreater(stability["net_level_drift"], 0.0)

    def test_critical_model_is_rejected(self):
        document = load_example("mm1.json")
        document["name"] = "critical M/M/1"
        document["boundary"]["level_0_same"] = [[-2.0]]
        document["boundary"]["level_0_up"] = [[2.0]]
        document["boundary"]["level_1_down"] = [[2.0]]
        document["boundary"]["level_1_same"] = [[-4.0]]
        document["interior"]["down"] = [[2.0]]
        document["interior"]["same"] = [[-4.0]]
        document["interior"]["up"] = [[2.0]]

        with self.assertRaises(qbd_solver.QBDStabilityError) as context:
            qbd_solver.solve_document(document)
        self.assertEqual(
            context.exception.details["stability"]["classification"],
            "null_recurrent_or_critical",
        )

    def test_invalid_generator_row_sum_is_rejected(self):
        document = load_example("mm1.json")
        document["interior"]["same"] = [[-4.5]]
        with self.assertRaises(qbd_solver.QBDInputError) as context:
            qbd_solver.solve_document(document)
        self.assertIn("sums to", str(context.exception))

    def test_nonunique_reducible_boundary_is_rejected(self):
        document = {
            "boundary": {
                "level_0_same": [
                    [-1.0, 1.0, 0.0],
                    [1.0, -1.0, 0.0],
                    [0.0, 0.0, -0.2],
                ],
                "level_0_up": [[0.0], [0.0], [0.2]],
                "level_1_down": [[0.0, 0.0, 0.5]],
                "level_1_same": [[-0.7]],
            },
            "interior": {
                "down": [[0.5]],
                "same": [[-0.7]],
                "up": [[0.2]],
            },
        }
        with self.assertRaises(qbd_solver.QBDInputError) as context:
            qbd_solver.solve_document(document)
        self.assertIn("boundary/interior phase graph is reducible", str(context.exception))

    def test_iteration_limit_returns_convergence_diagnostics(self):
        document = load_example("mm1.json")
        document["solver"]["max_iterations"] = 1
        with self.assertRaises(qbd_solver.QBDConvergenceError) as context:
            qbd_solver.solve_document(document)
        self.assertEqual(context.exception.details["iterations"], 1)
        self.assertIn("partial_rate_matrix", context.exception.details)

    def test_near_critical_model_converges_with_visible_margin(self):
        document = {
            "boundary": {
                "level_0_same": [[-0.499]],
                "level_0_up": [[0.499]],
                "level_1_down": [[0.5]],
                "level_1_same": [[-0.999]],
            },
            "interior": {
                "down": [[0.5]],
                "same": [[-0.999]],
                "up": [[0.499]],
            },
            "solver": {"max_report_level": 0, "tail_levels": [10000]},
        }
        result = qbd_solver.solve_document(document)
        diagnostics = result["diagnostics"]

        self.assertClose(result["rate_matrix"][0][0], 0.998, 2.0e-9)
        self.assertGreater(diagnostics["iterations"], 1000)
        self.assertClose(
            diagnostics["rate_spectral_radius_certificate_margin"], 0.002, 2.0e-9
        )
        self.assertGreater(diagnostics["fundamental_matrix_inf_norm"], 499.0)
        self.assertClose(
            result["tail_probabilities"][0]["probability"],
            0.998**10000,
            5.0e-14,
        )

    def test_cli_emits_json_for_success_and_stability_error(self):
        success = subprocess.run(
            [sys.executable, str(ROOT / "qbd_solver.py"), "examples/mm1.json", "--compact"],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(success.returncode, 0, success.stderr)
        self.assertEqual(json.loads(success.stdout)["status"], "ok")

        failure = subprocess.run(
            [
                sys.executable,
                str(ROOT / "qbd_solver.py"),
                "examples/unstable_mm1.json",
                "--compact",
            ],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(failure.returncode, 2, failure.stderr)
        error = json.loads(failure.stdout)
        self.assertEqual(error["status"], "error")
        self.assertEqual(error["error"]["code"], "not_positive_recurrent")
        self.assertEqual(error["error"]["stability"]["classification"], "transient")

    def test_cli_human_output_has_stable_metric_and_evidence_records(self):
        success = subprocess.run(
            [sys.executable, str(ROOT / "qbd_solver.py"), "examples/mm1.json", "--human"],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(success.returncode, 0, success.stderr)
        lines = success.stdout.splitlines()
        self.assertIn(
            "QNET_QBD_EVIDENCE_V1 key=stability_classification value=positive_recurrent",
            lines,
        )
        mean = next(
            line for line in lines
            if line.startswith("QNET_QBD_METRIC_V1 metric=mean_level ")
        )
        self.assertAlmostEqual(float(mean.split("estimate=", 1)[1]), 2.0, places=8)
        self.assertTrue(any(
            line.startswith(
                "QNET_QBD_METRIC_V1 metric=tail_probability level=5 estimate="
            )
            for line in lines
        ))

        failure = subprocess.run(
            [
                sys.executable,
                str(ROOT / "qbd_solver.py"),
                "examples/unstable_mm1.json",
                "--human",
            ],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(failure.returncode, 2, failure.stderr)
        self.assertTrue(failure.stdout.startswith(
            "QNET_QBD_ERROR_V1 code=not_positive_recurrent message="
        ))


if __name__ == "__main__":
    unittest.main()
