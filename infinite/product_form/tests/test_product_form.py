from __future__ import annotations

import json
import subprocess
import sys
import unittest
from pathlib import Path


MODULE_DIR = Path(__file__).resolve().parents[1]
if str(MODULE_DIR) not in sys.path:
    sys.path.insert(0, str(MODULE_DIR))

from bcmp import parse_bcmp, solve_bcmp  # noqa: E402
from common import ConfigError, StateSpaceLimitError  # noqa: E402
from kaufman_roberts import (  # noqa: E402
    parse_kaufman_roberts,
    solve_kaufman_roberts,
)
from solver import load_document, solve_document  # noqa: E402


class ClosedBCMPAnalyticalTests(unittest.TestCase):
    def test_machine_repair_example_has_hand_derived_distribution(self):
        model = parse_bcmp(
            load_document(MODULE_DIR / "examples" / "closed_single_class.json")
        )
        result = solve_bcmp(model, include_states=True)
        expected_by_cpu_population = {0: 0.4, 1: 0.4, 2: 0.2}
        actual_by_cpu_population = {}
        for item in result["stationary_distribution"]:
            cpu_population = item["state"]["cpu"]["job"]
            actual_by_cpu_population[cpu_population] = item["probability"]
        self.assertEqual(set(actual_by_cpu_population), set(expected_by_cpu_population))
        for population, target in expected_by_cpu_population.items():
            self.assertAlmostEqual(
                actual_by_cpu_population[population], target, delta=2.0e-13
            )

        classes = result["measures"]["classes"]
        stations = {item["id"]: item for item in result["measures"]["stations"]}
        self.assertAlmostEqual(classes[0]["reference_throughput"], 0.6, delta=2.0e-13)
        self.assertAlmostEqual(
            classes[0]["mean_time_per_reference_visit"], 10.0 / 3.0, delta=2.0e-12
        )
        self.assertAlmostEqual(stations["cpu"]["mean_number"], 0.8, delta=2.0e-13)
        self.assertAlmostEqual(stations["think"]["mean_number"], 1.2, delta=2.0e-13)
        self.assertAlmostEqual(stations["cpu"]["server_utilization"], 0.6, delta=2.0e-13)
        self.assertIsNone(stations["think"]["server_utilization"])
        self.assertLess(
            result["solver"]["maximum_throughput_cross_check_residual"], 1.0e-12
        )

    def test_two_class_processor_sharing_product_factor(self):
        document = {
            "schema_version": 1,
            "model_type": "closed_bcmp",
            "name": "two-class PS reference",
            "stations": [
                {
                    "id": "p1",
                    "type": "processor_sharing",
                    "service_times": {"A": 1.0, "B": 1.0},
                },
                {
                    "id": "p2",
                    "type": "processor_sharing",
                    "service_times": {"A": 1.0, "B": 1.0},
                },
            ],
            "classes": [
                {
                    "id": "A",
                    "population": 1,
                    "reference_station": "p1",
                    "visit_ratios": {"p1": 1.0, "p2": 1.0},
                },
                {
                    "id": "B",
                    "population": 1,
                    "reference_station": "p1",
                    "visit_ratios": {"p1": 1.0, "p2": 1.0},
                },
            ],
        }
        result = solve_bcmp(parse_bcmp(document), include_states=True)
        expected = {
            ((1, 1), (0, 0)): 1.0 / 3.0,
            ((0, 0), (1, 1)): 1.0 / 3.0,
            ((1, 0), (0, 1)): 1.0 / 6.0,
            ((0, 1), (1, 0)): 1.0 / 6.0,
        }
        actual = {}
        for item in result["stationary_distribution"]:
            state = item["state"]
            key = (
                (state["p1"]["A"], state["p1"]["B"]),
                (state["p2"]["A"], state["p2"]["B"]),
            )
            actual[key] = item["probability"]
        self.assertEqual(set(actual), set(expected))
        for state, target in expected.items():
            self.assertAlmostEqual(actual[state], target, delta=2.0e-13)
        for class_result in result["measures"]["classes"]:
            self.assertAlmostEqual(
                class_result["reference_throughput"], 1.0 / 3.0, delta=2.0e-13
            )
        self.assertLess(
            result["solver"]["maximum_population_residual"], 1.0e-13
        )
        self.assertLess(
            result["solver"]["maximum_throughput_cross_check_residual"], 1.0e-12
        )

    def test_multiserver_fcfs_factor_and_throughput(self):
        document = {
            "schema_version": 1,
            "model_type": "closed_bcmp",
            "name": "three jobs at two servers",
            "stations": [
                {
                    "id": "pool",
                    "type": "fcfs",
                    "servers": 2,
                    "service_times": {"job": 1.0},
                }
            ],
            "classes": [
                {
                    "id": "job",
                    "population": 3,
                    "visit_ratios": {"pool": 1.0},
                }
            ],
        }
        result = solve_bcmp(parse_bcmp(document), include_states=True)
        self.assertEqual(result["solver"]["state_count"], 1)
        self.assertAlmostEqual(
            result["measures"]["classes"][0]["reference_throughput"],
            2.0,
            delta=2.0e-13,
        )
        station = result["measures"]["stations"][0]
        self.assertAlmostEqual(station["mean_number"], 3.0, delta=1.0e-14)
        self.assertAlmostEqual(
            station["mean_active_service_positions"], 2.0, delta=1.0e-14
        )
        self.assertAlmostEqual(station["server_utilization"], 1.0, delta=1.0e-14)
        self.assertAlmostEqual(station["throughput"], 2.0, delta=2.0e-13)

    def test_multiclass_catalogue_conserves_every_population_and_flow(self):
        model = parse_bcmp(
            load_document(MODULE_DIR / "examples" / "closed_multiclass_bcmp.json")
        )
        result = solve_bcmp(model)
        self.assertEqual(result["solver"]["state_count"], 40)
        self.assertAlmostEqual(result["solver"]["probability_mass"], 1.0, delta=2.0e-14)
        self.assertLess(result["solver"]["maximum_population_residual"], 2.0e-13)
        self.assertLess(
            result["solver"]["maximum_throughput_cross_check_residual"], 2.0e-13
        )
        station_types = {
            station["type"] for station in result["measures"]["stations"]
        }
        self.assertEqual(
            station_types,
            {
                "fcfs",
                "processor_sharing",
                "infinite_server",
                "lcfs_preemptive_resume",
            },
        )


class ClosedBCMPValidationTests(unittest.TestCase):
    def test_fcfs_rejects_class_dependent_service_time(self):
        document = {
            "schema_version": 1,
            "model_type": "closed_bcmp",
            "name": "invalid FCFS",
            "stations": [
                {
                    "id": "s",
                    "type": "fcfs",
                    "service_times": {"A": 1.0, "B": 1.1},
                }
            ],
            "classes": [
                {"id": "A", "population": 1, "visit_ratios": {"s": 1.0}},
                {"id": "B", "population": 1, "visit_ratios": {"s": 1.0}},
            ],
        }
        with self.assertRaisesRegex(ConfigError, "class-independent"):
            parse_bcmp(document)

    def test_periodic_closed_routing_is_solved_without_power_iteration(self):
        model = parse_bcmp(
            load_document(MODULE_DIR / "examples" / "closed_single_class.json")
        )
        visits = model.classes[0].visit_ratios
        self.assertEqual(visits, (1.0, 1.0))

    def test_state_limit_is_enforced_before_enumeration(self):
        document = load_document(
            MODULE_DIR / "examples" / "closed_multiclass_bcmp.json"
        )
        document = dict(document)
        document["solver"] = {"max_states": 10}
        with self.assertRaises(StateSpaceLimitError):
            solve_bcmp(parse_bcmp(document))

    def test_unknown_mixed_alias_is_explicitly_rejected(self):
        with self.assertRaisesRegex(ConfigError, "use 'mixed_bcmp'"):
            solve_document(
                {
                    "schema_version": 1,
                    "model_type": "mixed_open_closed",
                    "name": "not silently approximated",
                }
            )


class KaufmanRobertsAnalyticalTests(unittest.TestCase):
    def test_single_class_matches_erlang_loss_weights(self):
        document = {
            "schema_version": 1,
            "model_type": "kaufman_roberts",
            "name": "Erlang B capacity two",
            "resource": {"id": "link", "capacity": 2},
            "classes": [
                {
                    "id": "call",
                    "units": 1,
                    "arrival_rate": 2.0,
                    "mean_holding_time": 0.5,
                }
            ],
        }
        result = solve_kaufman_roberts(parse_kaufman_roberts(document))
        probabilities = [
            item["probability"]
            for item in result["measures"]["occupancy_distribution"]
        ]
        for actual, target in zip(probabilities, (0.4, 0.4, 0.2)):
            self.assertAlmostEqual(actual, target, delta=2.0e-14)
        loss_class = result["measures"]["classes"][0]
        self.assertAlmostEqual(loss_class["blocking_probability"], 0.2, delta=2.0e-14)
        self.assertAlmostEqual(loss_class["carried_load"], 0.8, delta=2.0e-14)
        self.assertAlmostEqual(loss_class["accepted_arrival_rate"], 1.6, delta=2.0e-14)
        self.assertAlmostEqual(loss_class["loss_rate"], 0.4, delta=2.0e-14)

    def test_two_request_sizes_match_hand_recursion(self):
        document = {
            "schema_version": 1,
            "model_type": "kaufman_roberts",
            "name": "capacity three multi-rate reference",
            "resource": {"id": "link", "capacity": 3},
            "classes": [
                {"id": "small", "units": 1, "offered_load": 1.0},
                {"id": "large", "units": 2, "offered_load": 1.0},
            ],
        }
        result = solve_kaufman_roberts(parse_kaufman_roberts(document))
        probabilities = [
            item["probability"]
            for item in result["measures"]["occupancy_distribution"]
        ]
        expected = (3.0 / 14.0, 3.0 / 14.0, 9.0 / 28.0, 1.0 / 4.0)
        for actual, target in zip(probabilities, expected):
            self.assertAlmostEqual(actual, target, delta=2.0e-14)
        classes = {item["id"]: item for item in result["measures"]["classes"]}
        self.assertAlmostEqual(
            classes["small"]["blocking_probability"], 1.0 / 4.0, delta=2.0e-14
        )
        self.assertAlmostEqual(
            classes["large"]["blocking_probability"], 4.0 / 7.0, delta=2.0e-14
        )
        resource = result["measures"]["resource"]
        self.assertAlmostEqual(
            resource["mean_units_occupied"], 45.0 / 28.0, delta=2.0e-14
        )
        self.assertLess(
            abs(result["solver"]["mean_occupancy_conservation_residual"]),
            2.0e-14,
        )

    def test_log_domain_recursion_handles_extreme_offered_load(self):
        document = {
            "schema_version": 1,
            "model_type": "kaufman_roberts",
            "name": "large load",
            "resource": {"id": "link", "capacity": 100},
            "classes": [
                {"id": "call", "units": 1, "offered_load": 1.0e250}
            ],
        }
        result = solve_kaufman_roberts(parse_kaufman_roberts(document))
        solver = result["solver"]
        resource = result["measures"]["resource"]
        self.assertAlmostEqual(solver["probability_mass"], 1.0, delta=1.0e-13)
        self.assertGreater(resource["mean_units_occupied"], 99.999999)
        self.assertLess(
            abs(solver["mean_occupancy_conservation_residual"]), 1.0e-8
        )

    def test_capacity_safety_limit_is_explicit(self):
        document = {
            "schema_version": 1,
            "model_type": "kaufman_roberts",
            "name": "capacity guard",
            "resource": {"id": "link", "capacity": 11},
            "classes": [
                {"id": "call", "units": 1, "offered_load": 1.0}
            ],
            "solver": {"max_capacity": 10},
        }
        with self.assertRaisesRegex(ConfigError, "max_capacity"):
            parse_kaufman_roberts(document)


class CommandLineAndSchemaTests(unittest.TestCase):
    def test_json_documents_and_schema_are_well_formed(self):
        paths = [
            MODULE_DIR / "schema.json",
            MODULE_DIR / "examples" / "closed_single_class.json",
            MODULE_DIR / "examples" / "closed_multiclass_bcmp.json",
            MODULE_DIR / "examples" / "open_multiclass_bcmp.json",
            MODULE_DIR / "examples" / "mixed_bcmp.json",
            MODULE_DIR / "examples" / "multirate_loss.json",
        ]
        for path in paths:
            with self.subTest(path=path.name):
                with path.open("r", encoding="utf-8") as stream:
                    self.assertIsInstance(json.load(stream), dict)

    def test_cli_json_contains_closed_distribution_on_request(self):
        completed = subprocess.run(
            [
                sys.executable,
                str(MODULE_DIR / "solver.py"),
                str(MODULE_DIR / "examples" / "closed_single_class.json"),
                "--json",
                "--include-states",
            ],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertEqual(completed.returncode, 0, msg=completed.stderr)
        result = json.loads(completed.stdout)
        self.assertEqual(result["model_type"], "closed_bcmp")
        self.assertEqual(len(result["stationary_distribution"]), 3)
        self.assertAlmostEqual(
            sum(item["probability"] for item in result["stationary_distribution"]),
            1.0,
            delta=2.0e-14,
        )


if __name__ == "__main__":
    unittest.main()
