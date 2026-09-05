from __future__ import annotations

import json
import math
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from fbna_decomp import InputError, mmck, parse_document, solve_document  # noqa: E402


class MMcKTests(unittest.TestCase):
    def test_mm1k_matches_closed_form(self) -> None:
        arrival = 0.8
        service = 1.0
        capacity = 5
        rho = arrival / service
        normalizer = sum(rho**n for n in range(capacity + 1))
        expected_probabilities = [rho**n / normalizer for n in range(capacity + 1)]
        expected_mean = sum(
            n * expected_probabilities[n] for n in range(capacity + 1)
        )
        expected_throughput = arrival * (1.0 - expected_probabilities[-1])

        result = mmck(arrival, service, servers=1, capacity=capacity)

        for actual, expected in zip(result.probabilities, expected_probabilities):
            self.assertAlmostEqual(actual, expected, places=14)
        self.assertAlmostEqual(
            result.blocking_probability, expected_probabilities[-1], places=14
        )
        self.assertAlmostEqual(result.mean_number, expected_mean, places=14)
        self.assertAlmostEqual(result.throughput, expected_throughput, places=14)
        self.assertLess(result.flow_balance_residual, 1.0e-14)

    def test_mm1k_rho_one_is_uniform(self) -> None:
        result = mmck(2.0, 2.0, servers=1, capacity=7)
        for probability in result.probabilities:
            self.assertAlmostEqual(probability, 1.0 / 8.0, places=14)
        self.assertAlmostEqual(result.mean_number, 3.5, places=14)

    def test_single_station_document_is_exact_special_case(self) -> None:
        document = json.loads((ROOT / "examples/mm1k_loss.json").read_text())
        result = solve_document(document)
        direct = mmck(0.8, 1.0, servers=1, capacity=5)
        station = result["stations"][0]
        self.assertTrue(result["convergence"]["converged"])
        self.assertEqual(result["convergence"]["iterations"], 1)
        self.assertAlmostEqual(
            station["blocking_probability"], direct.blocking_probability, places=14
        )
        self.assertAlmostEqual(station["mean_number"], direct.mean_number, places=14)
        self.assertAlmostEqual(station["throughput"], direct.throughput, places=14)
        self.assertLess(result["network"]["flow_conservation_residual"], 1.0e-13)


class NetworkFlowTests(unittest.TestCase):
    def test_multiclass_feedback_loss_conserves_routing(self) -> None:
        document = json.loads(
            (ROOT / "examples/multiclass_feedback_loss.json").read_text()
        )
        result = solve_document(document)

        self.assertTrue(result["convergence"]["converged"])
        self.assertLess(result["convergence"]["residual"], 1.0e-11)
        self.assertLess(result["network"]["flow_conservation_residual"], 1.0e-10)
        self.assertLess(
            result["network"]["maximum_class_conservation_residual"], 1.0e-10
        )
        for station in result["stations"]:
            self.assertLess(station["station_flow_conservation_residual"], 1.0e-9)
            self.assertAlmostEqual(
                sum(item["mean_number"] for item in station["classes"]),
                station["mean_number"],
                places=9,
            )

        network = result["network"]
        self.assertAlmostEqual(
            network["external_offered_rate"],
            network["external_loss_rate"]
            + network["internal_loss_rate"]
            + network["exit_rate"],
            places=10,
        )

    def test_class_transition_balance_and_bas_label(self) -> None:
        document = json.loads(
            (ROOT / "examples/multiclass_bas_approx.json").read_text()
        )
        result = solve_document(document)

        self.assertTrue(result["convergence"]["converged"])
        self.assertTrue(result["semantics"]["bas_is_approximation"])
        self.assertFalse(result["semantics"]["loss_semantics_complete"])
        self.assertEqual(result["network"]["internal_loss_rate"], 0.0)
        self.assertLess(result["network"]["flow_conservation_residual"], 1.0e-8)
        self.assertLess(
            result["network"]["maximum_class_conservation_residual"], 1.0e-8
        )
        rework = next(item for item in result["classes"] if item["id"] == "rework")
        self.assertGreater(rework["transition_in_rate"], 0.0)
        self.assertIsNone(rework["mean_time_in_network_until_exit_or_loss"])
        self.assertIsNotNone(rework["mean_residence_time_in_class"])
        self.assertTrue(any("BAS results" in warning for warning in result["warnings"]))

    def test_rejects_externally_reachable_closed_routing_class(self) -> None:
        document = {
            "schema_version": 1,
            "blocking": "loss",
            "stations": [
                {"id": "s", "servers": 1, "capacity": 2, "service_rate": 1.0}
            ],
            "classes": [{"id": "c", "external_arrivals": {"s": 0.2}}],
            "routes": [
                {"class": "c", "from": "s", "to": "s", "probability": 1.0}
            ],
        }
        with self.assertRaisesRegex(InputError, "network is not open"):
            parse_document(document)


class CommandLineTests(unittest.TestCase):
    def test_json_cli_is_strict_and_deterministic(self) -> None:
        command = [
            sys.executable,
            str(ROOT / "fbna_decomp.py"),
            str(ROOT / "examples/mm1k_loss.json"),
            "--compact",
        ]
        first = subprocess.run(command, check=True, text=True, capture_output=True)
        second = subprocess.run(command, check=True, text=True, capture_output=True)
        self.assertEqual(first.stdout, second.stdout)
        payload = json.loads(first.stdout)
        self.assertEqual(payload["status"], "converged")
        self.assertFalse(any(math.isnan(value) for value in _numbers(payload)))

    def test_text_cli_contains_convergence_and_station_metrics(self) -> None:
        command = [
            sys.executable,
            str(ROOT / "fbna_decomp.py"),
            str(ROOT / "examples/mm1k_loss.json"),
            "--format",
            "text",
        ]
        completed = subprocess.run(command, check=True, text=True, capture_output=True)
        self.assertIn("Convergence: iterations=1", completed.stdout)
        self.assertIn("P(full)=", completed.stdout)
        self.assertIn("residual=", completed.stdout)


def _numbers(value):
    if isinstance(value, bool):
        return
    if isinstance(value, (int, float)):
        yield float(value)
    elif isinstance(value, list):
        for item in value:
            yield from _numbers(item)
    elif isinstance(value, dict):
        for item in value.values():
            yield from _numbers(item)


if __name__ == "__main__":
    unittest.main()
