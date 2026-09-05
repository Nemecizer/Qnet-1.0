from __future__ import annotations

import json
import subprocess
import sys
import unittest
from pathlib import Path


MODULE_DIR = Path(__file__).resolve().parents[1]
if str(MODULE_DIR) not in sys.path:
    sys.path.insert(0, str(MODULE_DIR))

from solver import (  # noqa: E402
    ConfigError,
    StateSpaceLimitError,
    enumerate_chain,
    load_model,
    parse_model,
    solve_model,
)


def mm1k_document(capacity: int, arrival_rate: float, service_rate: float):
    return {
        "schema_version": 1,
        "name": "M/M/1/K test",
        "blocking": "loss",
        "service_discipline": "fcfs",
        "classes": ["job"],
        "stations": [
            {
                "id": "server",
                "servers": 1,
                "capacity": capacity,
                "service_rates": {"job": service_rate},
            }
        ],
        "external_arrivals": [
            {"station": "server", "class": "job", "rate": arrival_rate}
        ],
        "routing": [],
        "solver": {
            "tolerance": 1.0e-14,
            "max_iterations": 200000,
            "max_states": 100,
        },
    }


class AnalyticalMM1KTests(unittest.TestCase):
    def test_full_stationary_distribution_and_measures(self):
        capacity = 4
        arrival_rate = 2.0
        service_rate = 3.0
        rho = arrival_rate / service_rate
        model = parse_model(mm1k_document(capacity, arrival_rate, service_rate))
        chain, solution, measures = solve_model(model)

        self.assertTrue(solution.converged)
        self.assertEqual(len(chain.states), capacity + 1)
        normalizer = sum(rho**n for n in range(capacity + 1))
        expected = [(rho**n) / normalizer for n in range(capacity + 1)]
        actual_by_population = [0.0] * (capacity + 1)
        for state, probability in zip(chain.states, solution.probabilities):
            actual_by_population[len(state[0])] += probability
        for actual, target in zip(actual_by_population, expected):
            self.assertAlmostEqual(actual, target, delta=2.0e-12)

        expected_mean = sum(n * expected[n] for n in range(capacity + 1))
        expected_accepted = arrival_rate * (1.0 - expected[-1])
        station = measures["stations"][0]
        network = measures["network"]
        self.assertAlmostEqual(station["mean_number"], expected_mean, delta=2.0e-12)
        self.assertAlmostEqual(
            station["probability_full"], expected[-1], delta=2.0e-12
        )
        self.assertAlmostEqual(
            station["service_completion_rate"], expected_accepted, delta=2.0e-12
        )
        self.assertAlmostEqual(
            network["external_loss_rate"], arrival_rate * expected[-1], delta=2.0e-12
        )
        self.assertAlmostEqual(
            station["mean_sojourn_time"], expected_mean / expected_accepted, delta=2.0e-12
        )
        self.assertLess(solution.generator_residual_l1, 1.0e-11)
        self.assertLess(abs(network["population_flow_residual"]), 1.0e-11)

    def test_rho_one_distribution_is_uniform(self):
        capacity = 5
        model = parse_model(mm1k_document(capacity, 2.0, 2.0))
        chain, solution, measures = solve_model(model)
        target = 1.0 / (capacity + 1)
        actual_by_population = [0.0] * (capacity + 1)
        for state, probability in zip(chain.states, solution.probabilities):
            actual_by_population[len(state[0])] += probability
        for actual in actual_by_population:
            self.assertAlmostEqual(actual, target, delta=2.0e-12)
        self.assertAlmostEqual(
            measures["stations"][0]["mean_number"], capacity / 2.0, delta=2.0e-12
        )

    def test_multiserver_loss_system_uses_all_service_clocks(self):
        document = mm1k_document(2, 2.0, 1.0)
        document["name"] = "M/M/2/2 test"
        document["stations"][0]["servers"] = 2
        model = parse_model(document)
        chain, solution, measures = solve_model(model)
        actual_by_population = [0.0, 0.0, 0.0]
        for state, probability in zip(chain.states, solution.probabilities):
            actual_by_population[len(state[0])] += probability
        for actual, target in zip(actual_by_population, (0.2, 0.4, 0.4)):
            self.assertAlmostEqual(actual, target, delta=2.0e-12)
        station = measures["stations"][0]
        self.assertAlmostEqual(station["mean_number"], 1.2, delta=2.0e-12)
        self.assertAlmostEqual(station["mean_in_service"], 1.2, delta=2.0e-12)
        self.assertAlmostEqual(station["server_utilization"], 0.6, delta=2.0e-12)
        self.assertAlmostEqual(station["service_completion_rate"], 1.2, delta=2.0e-12)
        self.assertAlmostEqual(station["mean_sojourn_time"], 1.0, delta=2.0e-12)


class OrderedClassStateTests(unittest.TestCase):
    def test_multiclass_fcfs_station_preserves_queue_order(self):
        document = {
            "schema_version": 1,
            "name": "ordered two-class station",
            "classes": ["A", "B"],
            "stations": [
                {
                    "id": "s",
                    "servers": 1,
                    "capacity": 2,
                    "service_rates": {"A": 1.0, "B": 2.0},
                }
            ],
            "external_arrivals": [
                {"station": "s", "class": "A", "rate": 1.0},
                {"station": "s", "class": "B", "rate": 1.0},
            ],
        }
        model = parse_model(document)
        chain, solution, measures = solve_model(
            model, tolerance=1.0e-14, max_iterations=200000
        )
        class_a = model.class_ids.index("A")
        class_b = model.class_ids.index("B")
        expected = {
            (): 5.0 / 23.0,
            (class_a,): 4.0 / 23.0,
            (class_b,): 3.0 / 23.0,
            (class_a, class_a): 4.0 / 23.0,
            (class_a, class_b): 4.0 / 23.0,
            (class_b, class_a): 3.0 / 46.0,
            (class_b, class_b): 3.0 / 46.0,
        }
        actual = {
            state[0]: probability
            for state, probability in zip(chain.states, solution.probabilities)
        }
        self.assertEqual(set(actual), set(expected))
        for state, target in expected.items():
            self.assertAlmostEqual(actual[state], target, delta=2.0e-12)
        self.assertNotAlmostEqual(
            actual[(class_a, class_b)], actual[(class_b, class_a)], delta=1.0e-3
        )

        station = measures["stations"][0]
        by_class = {item["class"]: item for item in station["classes"]}
        self.assertAlmostEqual(station["probability_full"], 11.0 / 23.0, delta=2.0e-12)
        self.assertAlmostEqual(station["server_utilization"], 18.0 / 23.0, delta=2.0e-12)
        self.assertAlmostEqual(by_class["A"]["mean_number"], 35.0 / 46.0, delta=2.0e-12)
        self.assertAlmostEqual(by_class["B"]["mean_number"], 0.5, delta=2.0e-12)
        self.assertAlmostEqual(
            by_class["A"]["service_completion_rate"], 12.0 / 23.0, delta=2.0e-12
        )
        self.assertAlmostEqual(
            by_class["B"]["service_completion_rate"], 12.0 / 23.0, delta=2.0e-12
        )
        self.assertAlmostEqual(by_class["A"]["mean_sojourn_time"], 35.0 / 24.0, delta=2.0e-12)
        self.assertAlmostEqual(by_class["B"]["mean_sojourn_time"], 23.0 / 24.0, delta=2.0e-12)

    def test_same_station_feedback_reward_survives_generator_aggregation(self):
        document = mm1k_document(1, 1.0, 2.0)
        document["routing"] = [
            {
                "from_station": "server",
                "from_class": "job",
                "destinations": [
                    {"station": "server", "class": "job", "probability": 0.5}
                ],
            }
        ]
        model = parse_model(document)
        chain, solution, measures = solve_model(model)
        self.assertEqual(len(chain.states), 2)
        self.assertAlmostEqual(chain.leaving_rates[0], 1.0, delta=1.0e-14)
        self.assertAlmostEqual(chain.leaving_rates[1], 1.0, delta=1.0e-14)
        self.assertAlmostEqual(solution.probabilities[0], 0.5, delta=2.0e-12)
        self.assertAlmostEqual(solution.probabilities[1], 0.5, delta=2.0e-12)
        station = measures["stations"][0]
        class_result = station["classes"][0]
        self.assertAlmostEqual(station["service_completion_rate"], 1.0, delta=2.0e-12)
        self.assertAlmostEqual(class_result["internal_accepted_rate"], 0.5, delta=2.0e-12)
        self.assertAlmostEqual(class_result["exit_rate"], 0.5, delta=2.0e-12)
        self.assertAlmostEqual(class_result["internal_loss_rate"], 0.0, delta=1.0e-14)
        self.assertAlmostEqual(station["accepted_arrival_rate"], 1.0, delta=2.0e-12)


class RoutedNetworkTests(unittest.TestCase):
    def setUp(self):
        self.example_path = MODULE_DIR / "examples" / "multiclass_routed.json"

    def test_multiclass_flow_conservation_and_internal_loss(self):
        model = load_model(self.example_path)
        chain, solution, measures = solve_model(model)
        self.assertTrue(solution.converged)
        self.assertGreater(len(chain.states), 20)
        self.assertGreater(chain.off_diagonal_count, len(chain.states))
        self.assertAlmostEqual(sum(solution.probabilities), 1.0, delta=2.0e-14)
        self.assertLess(solution.generator_residual_l1, 2.0e-10)

        network = measures["network"]
        self.assertAlmostEqual(network["external_arrival_rate"], 0.95, delta=1.0e-13)
        self.assertGreater(network["internal_arrival_rate"], 0.0)
        self.assertGreater(network["internal_loss_rate"], 0.0)
        self.assertLess(abs(network["population_flow_residual"]), 2.0e-10)
        self.assertLess(network["maximum_station_class_flow_residual"], 2.0e-10)

        station_by_id = {station["id"]: station for station in measures["stations"]}
        assembly = station_by_id["assembly"]
        self.assertEqual(assembly["servers"], 2)
        self.assertGreater(assembly["mean_in_service"], 0.0)
        self.assertLessEqual(assembly["server_utilization"], 1.0 + 1.0e-13)
        for station in measures["stations"]:
            self.assertLess(abs(station["flow_balance_residual"]), 2.0e-10)
            for class_result in station["classes"]:
                self.assertLess(abs(class_result["flow_balance_residual"]), 2.0e-10)

    def test_small_class_changing_route_has_exact_stationary_flows(self):
        document = {
            "schema_version": 1,
            "name": "four-state routed reference",
            "classes": ["A", "B"],
            "stations": [
                {
                    "id": "s1",
                    "servers": 1,
                    "capacity": 1,
                    "service_rates": {"A": 2.0},
                },
                {
                    "id": "s2",
                    "servers": 1,
                    "capacity": 1,
                    "service_rates": {"B": 3.0},
                },
            ],
            "external_arrivals": [
                {"station": "s1", "class": "A", "rate": 1.0}
            ],
            "routing": [
                {
                    "from_station": "s1",
                    "from_class": "A",
                    "destinations": [
                        {"station": "s2", "class": "B", "probability": 1.0}
                    ],
                }
            ],
        }
        model = parse_model(document)
        chain, solution, measures = solve_model(
            model, tolerance=1.0e-14, max_iterations=200000
        )
        class_a = model.class_ids.index("A")
        class_b = model.class_ids.index("B")
        expected = {
            ((), ()): 1.0 / 2.0,
            ((class_a,), ()): 3.0 / 10.0,
            ((), (class_b,)): 1.0 / 6.0,
            ((class_a,), (class_b,)): 1.0 / 30.0,
        }
        actual = {
            state: probability
            for state, probability in zip(chain.states, solution.probabilities)
        }
        self.assertEqual(set(actual), set(expected))
        for state, target in expected.items():
            self.assertAlmostEqual(actual[state], target, delta=2.0e-12)

        network = measures["network"]
        station_by_id = {station["id"]: station for station in measures["stations"]}
        s1 = station_by_id["s1"]
        s2 = station_by_id["s2"]
        self.assertAlmostEqual(s1["external_accepted_rate"], 2.0 / 3.0, delta=2.0e-12)
        self.assertAlmostEqual(s1["external_loss_rate"], 1.0 / 3.0, delta=2.0e-12)
        self.assertAlmostEqual(s1["service_completion_rate"], 2.0 / 3.0, delta=2.0e-12)
        self.assertAlmostEqual(s2["internal_accepted_rate"], 3.0 / 5.0, delta=2.0e-12)
        self.assertAlmostEqual(s2["internal_loss_rate"], 1.0 / 15.0, delta=2.0e-12)
        self.assertAlmostEqual(s2["service_completion_rate"], 3.0 / 5.0, delta=2.0e-12)
        self.assertAlmostEqual(network["exit_rate"], 3.0 / 5.0, delta=2.0e-12)
        self.assertLess(abs(network["population_flow_residual"]), 2.0e-12)

    def test_two_busy_servers_contribute_two_service_clocks(self):
        model = load_model(self.example_path)
        chain = enumerate_chain(model)
        class_a = model.class_ids.index("A")
        target_state = ((class_a, class_a), ())
        state_index = chain.states.index(target_state)
        total_generator_exit_rate = chain.leaving_rates[state_index]
        # Two A customers serve concurrently at rate 2.3 each. Every route
        # changes this state, so the minimal generator exit rate is 2*2.3;
        # the external arrival clocks add 0.7 + 0.25.
        self.assertAlmostEqual(
            total_generator_exit_rate, 2.0 * 2.3 + 0.7 + 0.25, delta=1.0e-13
        )


class ValidationAndCLITests(unittest.TestCase):
    def test_bas_is_explicitly_rejected(self):
        document = mm1k_document(3, 1.0, 2.0)
        document["blocking"] = "bas"
        with self.assertRaisesRegex(ConfigError, "BAS"):
            parse_model(document)

    def test_reachable_state_limit_is_not_silent(self):
        model = parse_model(mm1k_document(5, 1.0, 2.0))
        with self.assertRaises(StateSpaceLimitError):
            enumerate_chain(model, max_states=3)

    def test_non_open_routing_is_rejected(self):
        document = mm1k_document(1, 1.0, 2.0)
        document["routing"] = [
            {
                "from_station": "server",
                "from_class": "job",
                "destinations": [
                    {"station": "server", "class": "job", "probability": 1.0}
                ],
            }
        ]
        with self.assertRaisesRegex(ConfigError, "not open"):
            parse_model(document)

    def test_json_cli_output_includes_distribution_on_request(self):
        command = [
            sys.executable,
            str(MODULE_DIR / "solver.py"),
            str(MODULE_DIR / "examples" / "mm1k.json"),
            "--json",
            "--include-states",
        ]
        completed = subprocess.run(
            command,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertEqual(completed.returncode, 0, msg=completed.stderr)
        result = json.loads(completed.stdout)
        self.assertTrue(result["solver"]["converged"])
        self.assertEqual(result["solver"]["state_count"], 5)
        self.assertEqual(len(result["stationary_distribution"]), 5)
        self.assertAlmostEqual(
            sum(item["probability"] for item in result["stationary_distribution"]),
            1.0,
            delta=2.0e-14,
        )


if __name__ == "__main__":
    unittest.main()
