from __future__ import annotations

import json
import math
import subprocess
import sys
import unittest
from pathlib import Path


MODULE_DIR = Path(__file__).resolve().parents[1]
if str(MODULE_DIR) not in sys.path:
    sys.path.insert(0, str(MODULE_DIR))

from common import ConfigError, StateSpaceLimitError  # noqa: E402
from mixed_bcmp import parse_mixed_bcmp, solve_mixed_bcmp  # noqa: E402
from open_bcmp import parse_open_bcmp, solve_open_bcmp  # noqa: E402
from solver import load_document, solve_document  # noqa: E402


def one_station_open(
    station_type="processor_sharing",
    arrival_rate=0.4,
    service_time=1.0,
    routing=None,
    servers=None,
):
    station = {
        "id": "s",
        "type": station_type,
        "service_times": {"job": service_time},
    }
    if servers is not None:
        station["servers"] = servers
    class_obj = {
        "id": "job",
        "external_arrival_rates": {"s": arrival_rate},
    }
    if routing is not None:
        class_obj["routing"] = routing
    return {
        "schema_version": 1,
        "model_type": "open_bcmp",
        "name": "one-station open model",
        "stations": [station],
        "classes": [class_obj],
    }


def one_station_mixed(station_type="processor_sharing", open_rate=0.25):
    return {
        "schema_version": 1,
        "model_type": "mixed_bcmp",
        "name": "one-station mixed model",
        "stations": [
            {
                "id": "s",
                "type": station_type,
                "service_times": {"open": 1.0, "closed": 1.0},
            }
        ],
        "open_classes": [
            {
                "id": "open",
                "external_arrival_rates": {"s": open_rate},
            }
        ],
        "closed_classes": [
            {
                "id": "closed",
                "population": 1,
                "visit_ratios": {"s": 1.0},
            }
        ],
    }


class OpenBCMPAnalyticalTests(unittest.TestCase):
    def test_feedback_mm1_matches_geometric_queue(self):
        document = one_station_open(
            routing=[
                {
                    "from_station": "s",
                    "destinations": [{"station": "s", "probability": 0.5}],
                }
            ]
        )
        result = solve_open_bcmp(parse_open_bcmp(document))
        station = result["measures"]["stations"][0]
        open_class = result["measures"]["classes"][0]
        self.assertAlmostEqual(station["throughput"], 0.8, delta=2.0e-14)
        self.assertAlmostEqual(station["traffic_intensity"], 0.8, delta=2.0e-14)
        self.assertAlmostEqual(station["mean_number"], 4.0, delta=2.0e-13)
        self.assertAlmostEqual(station["probability_empty"], 0.2, delta=2.0e-14)
        self.assertAlmostEqual(open_class["departure_rate"], 0.4, delta=2.0e-14)
        self.assertAlmostEqual(open_class["mean_time_in_network"], 10.0, delta=3.0e-13)

    def test_two_class_processor_sharing_means(self):
        document = {
            "schema_version": 1,
            "model_type": "open_bcmp",
            "name": "two-class PS",
            "stations": [
                {
                    "id": "ps",
                    "type": "processor_sharing",
                    "service_times": {"A": 2.0, "B": 1.0},
                }
            ],
            "classes": [
                {"id": "A", "external_arrival_rates": {"ps": 0.2}},
                {"id": "B", "external_arrival_rates": {"ps": 0.1}},
            ],
        }
        result = solve_open_bcmp(parse_open_bcmp(document))
        station = result["measures"]["stations"][0]
        classes = {item["class"]: item for item in station["classes"]}
        self.assertAlmostEqual(station["offered_load"], 0.5, delta=1.0e-14)
        self.assertAlmostEqual(station["mean_number"], 1.0, delta=1.0e-14)
        self.assertAlmostEqual(classes["A"]["mean_number"], 0.8, delta=1.0e-14)
        self.assertAlmostEqual(classes["B"]["mean_number"], 0.2, delta=1.0e-14)
        self.assertAlmostEqual(
            classes["A"]["mean_residence_time_per_visit"], 4.0, delta=1.0e-14
        )

    def test_mm2_erlang_c_measures(self):
        result = solve_open_bcmp(
            parse_open_bcmp(
                one_station_open(
                    station_type="fcfs",
                    arrival_rate=1.0,
                    service_time=1.0,
                    servers=2,
                )
            )
        )
        station = result["measures"]["stations"][0]
        self.assertAlmostEqual(station["probability_empty"], 1.0 / 3.0, delta=2.0e-14)
        self.assertAlmostEqual(
            station["probability_all_servers_busy"], 1.0 / 3.0, delta=2.0e-14
        )
        self.assertAlmostEqual(station["mean_number"], 4.0 / 3.0, delta=2.0e-14)
        self.assertAlmostEqual(station["server_utilization"], 0.5, delta=2.0e-14)

    def test_infinite_server_is_poisson_and_always_stable(self):
        result = solve_open_bcmp(
            parse_open_bcmp(
                one_station_open(
                    station_type="infinite_server",
                    arrival_rate=10.0,
                    service_time=2.0,
                )
            )
        )
        station = result["measures"]["stations"][0]
        self.assertAlmostEqual(station["mean_number"], 20.0, delta=2.0e-14)
        self.assertAlmostEqual(
            station["probability_empty"], math.exp(-20.0), delta=1.0e-22
        )
        self.assertIsNone(station["traffic_intensity"])
        self.assertIsNone(result["solver"]["minimum_stability_margin"])

    def test_catalogue_example_conserves_every_open_class(self):
        result = solve_open_bcmp(
            parse_open_bcmp(
                load_document(MODULE_DIR / "examples" / "open_multiclass_bcmp.json")
            )
        )
        self.assertEqual(
            {item["type"] for item in result["measures"]["stations"]},
            {
                "fcfs",
                "processor_sharing",
                "infinite_server",
                "lcfs_preemptive_resume",
            },
        )
        self.assertLess(
            result["solver"]["maximum_traffic_equation_residual"], 1.0e-13
        )
        self.assertLess(
            result["solver"]["maximum_flow_conservation_residual"], 1.0e-13
        )
        for class_result in result["measures"]["classes"]:
            self.assertAlmostEqual(
                class_result["external_arrival_rate"],
                class_result["departure_rate"],
                delta=2.0e-13,
            )


class OpenBCMPValidationTests(unittest.TestCase):
    def test_trapped_routing_class_is_rejected(self):
        document = one_station_open(
            routing=[
                {
                    "from_station": "s",
                    "destinations": [{"station": "s", "probability": 1.0}],
                }
            ]
        )
        with self.assertRaisesRegex(ConfigError, "cannot reach an exit"):
            parse_open_bcmp(document)

    def test_explicit_row_probability_must_sum_to_one(self):
        document = one_station_open(
            routing=[
                {
                    "from_station": "s",
                    "destinations": [{"station": "s", "probability": 0.4}],
                    "exit_probability": 0.5,
                }
            ]
        )
        with self.assertRaisesRegex(ConfigError, "must sum to 1"):
            parse_open_bcmp(document)

    def test_unstable_single_server_is_rejected(self):
        with self.assertRaisesRegex(ConfigError, "unstable"):
            solve_open_bcmp(parse_open_bcmp(one_station_open(arrival_rate=1.0)))

    def test_fcfs_requires_class_independent_exponential_mean(self):
        document = {
            "schema_version": 1,
            "model_type": "open_bcmp",
            "name": "invalid FCFS",
            "stations": [
                {
                    "id": "s",
                    "type": "fcfs",
                    "service_times": {"A": 1.0, "B": 1.1},
                }
            ],
            "classes": [
                {"id": "A", "external_arrival_rates": {"s": 0.1}},
                {"id": "B", "external_arrival_rates": {"s": 0.1}},
            ],
        }
        with self.assertRaisesRegex(ConfigError, "class-independent"):
            parse_open_bcmp(document)

    def test_include_states_never_truncates_open_space(self):
        with self.assertRaisesRegex(ConfigError, "countably infinite"):
            solve_document(one_station_open(), include_states=True)

    def test_server_iteration_guard_is_explicit(self):
        document = one_station_open(
            station_type="fcfs", servers=3, arrival_rate=1.0
        )
        document["solver"] = {"max_servers": 2}
        with self.assertRaisesRegex(ConfigError, "max_servers"):
            parse_open_bcmp(document)

    def test_unreachable_routing_row_is_rejected(self):
        document = {
            "schema_version": 1,
            "model_type": "open_bcmp",
            "name": "unused routing row",
            "stations": [
                {"id": "a", "type": "infinite_server", "service_times": {"job": 1.0}},
                {"id": "b", "type": "infinite_server", "service_times": {"job": 1.0}},
            ],
            "classes": [
                {
                    "id": "job",
                    "external_arrival_rates": {"a": 0.1},
                    "routing": [{"from_station": "b"}],
                }
            ],
        }
        with self.assertRaisesRegex(ConfigError, "unreachable from external"):
            parse_open_bcmp(document)


class MixedBCMPAnalyticalTests(unittest.TestCase):
    def test_shared_ps_has_negative_binomial_open_marginal(self):
        result = solve_mixed_bcmp(parse_mixed_bcmp(one_station_mixed()), True)
        station = result["measures"]["stations"][0]
        classes = {item["class"]: item for item in station["classes"]}
        self.assertAlmostEqual(station["mean_closed_number"], 1.0, delta=1.0e-14)
        self.assertAlmostEqual(station["mean_open_number"], 2.0 / 3.0, delta=2.0e-14)
        self.assertAlmostEqual(classes["closed"]["throughput"], 0.75, delta=2.0e-14)
        self.assertAlmostEqual(classes["open"]["throughput"], 0.25, delta=2.0e-14)
        self.assertEqual(station["probability_empty"], 0.0)
        self.assertAlmostEqual(
            sum(item["probability"] for item in result["closed_marginal_distribution"]),
            1.0,
            delta=1.0e-14,
        )

    def test_shared_infinite_server_open_population_is_independent(self):
        document = one_station_mixed(
            station_type="infinite_server", open_rate=0.5
        )
        document["stations"][0]["service_times"] = {"open": 2.0, "closed": 2.0}
        result = solve_mixed_bcmp(parse_mixed_bcmp(document))
        station = result["measures"]["stations"][0]
        classes = {item["class"]: item for item in station["classes"]}
        self.assertAlmostEqual(classes["open"]["mean_number"], 1.0, delta=1.0e-14)
        self.assertAlmostEqual(classes["closed"]["mean_number"], 1.0, delta=1.0e-14)
        self.assertAlmostEqual(classes["closed"]["throughput"], 0.5, delta=1.0e-14)

    def test_shared_lcfs_preemptive_resume_uses_same_exact_marginal(self):
        result = solve_mixed_bcmp(
            parse_mixed_bcmp(
                one_station_mixed(station_type="lcfs_preemptive_resume")
            )
        )
        station = result["measures"]["stations"][0]
        classes = {item["class"]: item for item in station["classes"]}
        self.assertAlmostEqual(station["mean_open_number"], 2.0 / 3.0, delta=2.0e-14)
        self.assertAlmostEqual(classes["closed"]["throughput"], 0.75, delta=2.0e-14)

    def test_open_load_reshapes_two_station_closed_marginal_exactly(self):
        document = {
            "schema_version": 1,
            "model_type": "mixed_bcmp",
            "name": "two shared PS stations",
            "stations": [
                {
                    "id": "p1",
                    "type": "processor_sharing",
                    "service_times": {"open": 1.0, "closed": 0.7},
                },
                {
                    "id": "p2",
                    "type": "processor_sharing",
                    "service_times": {"open": 1.0, "closed": 1.2},
                },
            ],
            "open_classes": [
                {
                    "id": "open",
                    "external_arrival_rates": {"p1": 0.2, "p2": 0.3},
                }
            ],
            "closed_classes": [
                {
                    "id": "closed",
                    "population": 2,
                    "reference_station": "p1",
                    "visit_ratios": {"p1": 1.0, "p2": 1.0},
                }
            ],
        }
        result = solve_mixed_bcmp(parse_mixed_bcmp(document), include_states=True)
        effective_d1 = 0.7 / (1.0 - 0.2)
        effective_d2 = 1.2 / (1.0 - 0.3)
        weights = [
            effective_d2**2,
            effective_d1 * effective_d2,
            effective_d1**2,
        ]
        normalizer = sum(weights)
        expected_n1 = sum(index * weight for index, weight in enumerate(weights)) / normalizer
        expected_n2 = 2.0 - expected_n1
        stations = {item["id"]: item for item in result["measures"]["stations"]}
        self.assertAlmostEqual(
            stations["p1"]["mean_closed_number"], expected_n1, delta=2.0e-14
        )
        self.assertAlmostEqual(
            stations["p2"]["mean_closed_number"], expected_n2, delta=2.0e-14
        )
        self.assertAlmostEqual(
            stations["p1"]["mean_open_number"],
            0.2 * (expected_n1 + 1.0) / 0.8,
            delta=2.0e-14,
        )
        self.assertAlmostEqual(
            stations["p2"]["mean_open_number"],
            0.3 * (expected_n2 + 1.0) / 0.7,
            delta=2.0e-14,
        )
        expected_reference_throughput = (
            effective_d1 + effective_d2
        ) / normalizer
        self.assertAlmostEqual(
            result["measures"]["closed_classes"][0]["reference_throughput"],
            expected_reference_throughput,
            delta=2.0e-14,
        )

    def test_catalogue_example_supports_exclusive_fcfs_stations(self):
        result = solve_mixed_bcmp(
            parse_mixed_bcmp(
                load_document(MODULE_DIR / "examples" / "mixed_bcmp.json")
            ),
            include_states=True,
        )
        self.assertEqual(result["solver"]["closed_marginal_state_count"], 6)
        self.assertLess(
            result["solver"]["maximum_closed_population_residual"], 1.0e-13
        )
        stations = {item["id"]: item for item in result["measures"]["stations"]}
        self.assertGreater(stations["ingress"]["mean_open_number"], 0.0)
        self.assertEqual(stations["ingress"]["mean_closed_number"], 0.0)
        self.assertEqual(stations["batch_fcfs"]["mean_open_number"], 0.0)
        self.assertGreater(stations["batch_fcfs"]["mean_closed_number"], 0.0)


class MixedBCMPValidationTests(unittest.TestCase):
    def test_shared_fcfs_is_rejected_without_approximation(self):
        document = one_station_mixed(station_type="fcfs")
        with self.assertRaisesRegex(ConfigError, "does not support.*FCFS.*shared"):
            parse_mixed_bcmp(document)

    def test_unstable_open_subnetwork_is_rejected(self):
        with self.assertRaisesRegex(ConfigError, "unstable"):
            solve_mixed_bcmp(parse_mixed_bcmp(one_station_mixed(open_rate=1.0)))

    def test_closed_marginal_state_limit_is_enforced(self):
        document = load_document(MODULE_DIR / "examples" / "mixed_bcmp.json")
        document = dict(document)
        document["solver"] = {"max_states": 5}
        with self.assertRaises(StateSpaceLimitError):
            parse_mixed_bcmp(document)

    def test_zero_closed_population_uses_open_model_instead(self):
        document = one_station_mixed()
        document["closed_classes"][0]["population"] = 0
        with self.assertRaisesRegex(ConfigError, "use open_bcmp"):
            parse_mixed_bcmp(document)

    def test_legacy_mixed_alias_is_rejected_with_canonical_name(self):
        document = one_station_mixed()
        document["model_type"] = "mixed_open_closed"
        with self.assertRaisesRegex(ConfigError, "use 'mixed_bcmp'"):
            solve_document(document)


class OpenMixedCommandLineTests(unittest.TestCase):
    def test_open_cli_json_and_human_output(self):
        command = [
            sys.executable,
            str(MODULE_DIR / "solver.py"),
            str(MODULE_DIR / "examples" / "open_multiclass_bcmp.json"),
        ]
        human = subprocess.run(
            command,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertEqual(human.returncode, 0, msg=human.stderr)
        self.assertIn("Exact open BCMP", human.stdout)
        self.assertIn("minimum stability margin", human.stdout)
        structured = subprocess.run(
            command + ["--json"],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertEqual(structured.returncode, 0, msg=structured.stderr)
        result = json.loads(structured.stdout)
        self.assertEqual(result["model_type"], "open_bcmp")
        self.assertEqual(result["solver"]["probability_mass"], 1.0)

    def test_mixed_cli_exposes_closed_marginal_not_fake_full_state_space(self):
        completed = subprocess.run(
            [
                sys.executable,
                str(MODULE_DIR / "solver.py"),
                str(MODULE_DIR / "examples" / "mixed_bcmp.json"),
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
        self.assertIn("closed_marginal_distribution", result)
        self.assertNotIn("stationary_distribution", result)
        self.assertIn("countably infinite", result["solver"]["open_state_space"])


if __name__ == "__main__":
    unittest.main()
