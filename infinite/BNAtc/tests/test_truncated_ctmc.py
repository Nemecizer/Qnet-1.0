import copy
import json
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import truncated_ctmc  # noqa: E402


def load_example(name):
    with (ROOT / "examples" / name).open("r", encoding="utf-8") as handle:
        return json.load(handle)


class TruncatedCTMCTests(unittest.TestCase):
    def assertClose(self, actual, expected, tolerance=2.0e-9):
        self.assertLessEqual(abs(actual - expected), tolerance)

    def test_fixed_mm1_truncation_matches_exact_reflected_birth_death_chain(self):
        document = load_example("mm1.json")
        cap = 10
        document["solver"].update(
            {
                "initial_total_cap": cap,
                "max_total_cap": cap,
                "include_state_probabilities": True,
                "tail_levels": [0, 1, 5, cap, cap + 1],
            }
        )
        result = truncated_ctmc.solve_document(document)
        performance = result["approximation"]["performance"]
        probabilities = performance["state_probabilities"]
        rho = 2.0 / 3.0
        normalizer = (1.0 - rho) / (1.0 - rho ** (cap + 1))

        self.assertFalse(result["approximation"]["heuristic_converged"])
        self.assertEqual(result["approximation"]["termination_reason"], "max_total_cap_reached")
        self.assertEqual(performance["state_count"], cap + 1)
        for entry in probabilities:
            level = entry["state"][0]
            self.assertClose(entry["probability"], normalizer * rho**level)

        exact_truncated_mean = sum(
            level * normalizer * rho**level for level in range(cap + 1)
        )
        self.assertClose(performance["mean_total_jobs"], exact_truncated_mean)
        expected_boundary = normalizer * rho**cap
        self.assertClose(
            performance["boundary"]["probability_at_total_cap"], expected_boundary
        )
        tail_by_level = {
            entry["level_at_least"]: entry["estimate"]
            for entry in performance["tail_probabilities"]
        }
        self.assertClose(tail_by_level[0], 1.0)
        self.assertClose(tail_by_level[cap], expected_boundary)
        self.assertClose(tail_by_level[cap + 1], 0.0)

        stationary = result["diagnostics"]["stationary_solver"]
        self.assertFalse(stationary["matrix_materialized"])
        self.assertLess(stationary["uniformized_residual_l1"], 1.0e-12)
        self.assertLess(stationary["normalization_residual"], 1.0e-14)

    def test_mm1_traffic_solution_and_true_foster_bound_are_certified(self):
        document = load_example("mm1.json")
        document["solver"].update(
            {
                "initial_total_cap": 8,
                "max_total_cap": 8,
                "tail_levels": [9, 1_000_000],
            }
        )
        result = truncated_ctmc.solve_document(document)
        stability = result["stability"]
        certificate = result["certificates"]["foster_lyapunov"]

        self.assertTrue(stability["certified"])
        self.assertEqual(stability["classification"], "certified_positive_recurrent")
        self.assertClose(stability["throughput_by_node"][0], 2.0)
        self.assertClose(stability["utilization_by_node"][0], 2.0 / 3.0)
        self.assertTrue(certificate["certified"])
        self.assertEqual(certificate["scope"], "original_untruncated_ctmc")
        true_outside_mass = (2.0 / 3.0) ** 9
        self.assertGreaterEqual(
            certificate["bounds"]["probability_outside_selected_cap_upper"]
            + 1.0e-15,
            true_outside_mass,
        )
        very_far_tail = next(
            entry
            for entry in certificate["bounds"]["tail_probability_upper"]
            if entry["level_at_least"] == 1_000_000
        )
        self.assertGreater(very_far_tail["probability_upper"], 0.0)

    def test_adaptive_mm1_refines_and_approaches_infinite_mean(self):
        document = load_example("mm1.json")
        document["nodes"][0]["external_arrival_rate"] = 1.0
        document["solver"].update(
            {
                "initial_total_cap": 4,
                "max_total_cap": 32,
                "growth_factor": 2.0,
                "boundary_mass_tolerance": 1.0e-7,
                "refinement_relative_tolerance": 3.0e-6,
            }
        )
        result = truncated_ctmc.solve_document(document)
        approximation = result["approximation"]

        self.assertTrue(approximation["heuristic_converged"])
        self.assertGreater(len(result["refinement_history"]), 1)
        self.assertClose(
            approximation["performance"]["mean_total_jobs"], 0.5, 2.0e-6
        )
        self.assertLessEqual(
            approximation["performance"]["boundary"]["probability_at_total_cap"],
            document["solver"]["boundary_mass_tolerance"],
        )

    def test_tandem_is_stable_but_total_population_certificate_is_refused(self):
        document = load_example("tandem.json")
        document["solver"].update(
            {"initial_total_cap": 6, "max_total_cap": 6, "top_state_count": 5}
        )
        result = truncated_ctmc.solve_document(document)
        certificate = result["certificates"]["foster_lyapunov"]

        self.assertEqual(
            result["stability"]["classification"], "certified_positive_recurrent"
        )
        self.assertEqual(result["stability"]["throughput_by_node"], [0.4, 0.4])
        self.assertFalse(certificate["certified"])
        self.assertEqual(
            certificate["reason_code"],
            "sufficient_total_population_drift_condition_not_met",
        )
        self.assertTrue(certificate["refused_claims"])

    def test_uniformized_sparse_rows_preserve_probability(self):
        model = truncated_ctmc.parse_model(load_example("tandem.json"))
        operator = truncated_ctmc.build_operator(model, 4)
        for source in range(len(operator.states)):
            point_mass = [0.0 for _ in operator.states]
            point_mass[source] = 1.0
            image = operator.apply(point_mass)
            self.assertClose(sum(image), 1.0, 2.0e-14)
            self.assertTrue(all(value >= 0.0 for value in image))

    def test_unstable_network_is_rejected_before_truncation(self):
        with self.assertRaises(truncated_ctmc.StabilityError) as context:
            truncated_ctmc.solve_document(load_example("unstable_mm1.json"))
        stability = context.exception.details["stability"]
        self.assertEqual(stability["classification"], "certified_unstable")
        self.assertGreater(stability["utilization_by_node"][0], 1.0)

    def test_closed_routing_matrix_is_rejected(self):
        document = load_example("mm1.json")
        document["routing"] = [[1.0]]
        with self.assertRaises(truncated_ctmc.InputError) as context:
            truncated_ctmc.solve_document(document)
        self.assertIn("routing is not open", str(context.exception))

    def test_initial_state_limit_is_enforced_without_enumerating(self):
        document = load_example("tandem.json")
        document["solver"].update(
            {"initial_total_cap": 20, "max_total_cap": 20, "max_states": 10}
        )
        with self.assertRaises(truncated_ctmc.StateLimitError) as context:
            truncated_ctmc.solve_document(document)
        self.assertGreater(context.exception.details["required_states"], 10)

    def test_result_is_deterministic(self):
        document = load_example("tandem.json")
        document["solver"].update({"initial_total_cap": 5, "max_total_cap": 5})
        self.assertEqual(
            truncated_ctmc.solve_document(copy.deepcopy(document)),
            truncated_ctmc.solve_document(copy.deepcopy(document)),
        )

    def test_cli_emits_versioned_success_and_unstable_error(self):
        success = subprocess.run(
            [
                sys.executable,
                str(ROOT / "truncated_ctmc.py"),
                "examples/mm1.json",
                "--compact",
            ],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(success.returncode, 0, success.stderr)
        output = json.loads(success.stdout)
        self.assertEqual(output["schema_version"], 1)
        self.assertEqual(output["status"], "ok")

        human = subprocess.run(
            [
                sys.executable,
                str(ROOT / "truncated_ctmc.py"),
                "examples/mm1.json",
                "--human",
            ],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(human.returncode, 0, human.stderr)
        self.assertIn("Node 1 queue: E[N]=", human.stdout)
        self.assertIn("generator residual =", human.stdout)
        self.assertIn("Foster-Lyapunov certificate: certified", human.stdout)

        failure = subprocess.run(
            [
                sys.executable,
                str(ROOT / "truncated_ctmc.py"),
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
        self.assertEqual(error["schema_version"], 1)
        self.assertEqual(error["error"]["code"], "not_positive_recurrent")


if __name__ == "__main__":
    unittest.main()
