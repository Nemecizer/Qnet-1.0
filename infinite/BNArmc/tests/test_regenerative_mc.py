import copy
import json
import math
import subprocess
import sys
import unittest
from pathlib import Path
from urllib.parse import unquote


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import regenerative_mc as rmc  # noqa: E402


def load_example(name):
    with (ROOT / "examples" / name).open("r", encoding="utf-8") as handle:
        return json.load(handle)


def mm1k_document(capacity=5, arrival=0.8, service=1.0, cycles=1000):
    return {
        "name": "small deterministic test model",
        "nodes": [
            {
                "id": "queue",
                "servers": 1,
                "service_rate": service,
                "capacity": capacity,
            }
        ],
        "classes": [
            {
                "id": "jobs",
                "external_arrival_rates": {"queue": arrival},
                "routing": {"queue": {}},
            }
        ],
        "random": {"base_seed": 123456789, "stream": 3},
        "stopping": {
            "absolute_half_width": 1.0e-12,
            "relative_half_width": 0.0,
            "minimum_cycles": 30,
            "minimum_effective_cycles": 10,
            "check_every_cycles": 10,
            "maximum_cycles": cycles,
            "maximum_wall_seconds": 30.0,
        },
    }


class DistributionMathTests(unittest.TestCase):
    def assertClose(self, actual, expected, tolerance=1.0e-9):
        self.assertLessEqual(abs(actual - expected), tolerance)

    def test_student_t_quantiles_are_not_normal_shortcuts(self):
        self.assertClose(rmc.student_t_quantile(0.975, 1), 12.706204736, 2.0e-9)
        self.assertClose(rmc.student_t_quantile(0.975, 10), 2.228138852, 2.0e-9)
        self.assertClose(rmc.student_t_quantile(0.975, 29), 2.045229642, 2.0e-9)

    def test_seed_derivation_is_deterministic_and_stream_specific(self):
        first = rmc.derive_seed(42, 7, 11)
        self.assertEqual(first, rmc.derive_seed(42, 7, 11))
        self.assertNotEqual(first, rmc.derive_seed(42, 8, 11))
        self.assertNotEqual(first, rmc.derive_seed(42, 7, 12))


class SimulationTests(unittest.TestCase):
    def test_mm1_matches_formula_with_regenerative_uncertainty(self):
        result = rmc.solve_document(load_example("mm1.json"))
        estimate = result["estimates"]["mean_number_in_system"]
        benchmark = result["analytic_benchmark"]

        self.assertEqual(result["status"], "ok")
        self.assertEqual(benchmark["model"], "M/M/1")
        self.assertAlmostEqual(benchmark["mean_number_in_system"], 1.0)
        self.assertLess(
            abs(estimate["estimate"] - benchmark["mean_number_in_system"]),
            4.0 * estimate["standard_error"],
        )
        interval = estimate["confidence_interval"]
        self.assertLessEqual(interval["low"], benchmark["mean_number_in_system"])
        self.assertGreaterEqual(interval["high"], benchmark["mean_number_in_system"])
        self.assertGreater(estimate["effective_cycles"], 1000.0)
        self.assertIn("events within a cycle are not IID", result["regeneration"]["iid_unit"])

    def test_initial_nonempty_state_is_discarded_as_delayed_cycle(self):
        result = rmc.solve_document(load_example("multiclass_network.json"))
        regeneration = result["regeneration"]

        self.assertFalse(regeneration["initial_state_was_regeneration"])
        self.assertTrue(regeneration["delayed_first_cycle_discarded"])
        self.assertGreater(regeneration["delayed_time"], 0.0)
        self.assertGreaterEqual(regeneration["complete_cycles"], 300)
        self.assertAlmostEqual(
            result["traffic"]["classes"][0]["unblocked_traffic_equation_node_rates"]["cpu"],
            0.6 / 0.92,
            places=12,
        )
        estimates = result["estimates"]
        node_total = sum(
            estimates[f"mean_number_at_node:{node}"]["estimate"]
            for node in ("cpu", "io")
        )
        class_total = sum(
            estimates[f"mean_number_class:{customer}"]["estimate"]
            for customer in ("interactive", "batch")
        )
        self.assertAlmostEqual(
            estimates["mean_number_in_system"]["estimate"], node_total, places=12
        )
        self.assertAlmostEqual(
            estimates["mean_number_in_system"]["estimate"], class_total, places=12
        )
        # Every accepted external job leaves during its same complete cycle.
        self.assertAlmostEqual(
            estimates["external_accepted_rate"]["estimate"],
            estimates["departure_rate"]["estimate"],
            places=12,
        )

    def test_same_seed_and_stream_reproduce_complete_result(self):
        document = mm1k_document(cycles=200)
        first = rmc.solve_document(copy.deepcopy(document))
        second = rmc.solve_document(copy.deepcopy(document))
        self.assertEqual(first, second)

    def test_stream_changes_the_sample_path(self):
        document = mm1k_document(cycles=100)
        first = rmc.solve_document(copy.deepcopy(document))
        document["random"]["stream"] += 1
        second = rmc.solve_document(document)
        self.assertNotEqual(
            first["estimates"]["mean_number_in_system"]["estimate"],
            second["estimates"]["mean_number_in_system"]["estimate"],
        )

    def test_mm1k_crude_estimate_matches_exact_finite_buffer_formula(self):
        document = mm1k_document(capacity=5, arrival=0.8, service=1.0, cycles=12000)
        result = rmc.solve_document(document)
        estimate = result["estimates"]["external_blocking_probability"]
        exact = result["analytic_benchmark"]["external_blocking_probability"]

        self.assertEqual(result["analytic_benchmark"]["model"], "M/M/1/K")
        self.assertLess(abs(estimate["estimate"] - exact), 4.0 * estimate["standard_error"])
        self.assertLessEqual(estimate["confidence_interval"]["low"], exact)
        self.assertGreaterEqual(estimate["confidence_interval"]["high"], exact)
        estimates = result["estimates"]
        self.assertAlmostEqual(
            estimates["external_offered_rate"]["estimate"],
            estimates["external_accepted_rate"]["estimate"]
            + estimates["external_blocking_rate"]["estimate"],
            places=12,
        )

    def test_mm1k_formula_is_stable_when_arrival_rate_exceeds_service_rate(self):
        document = mm1k_document(capacity=3, arrival=2.0, service=1.0, cycles=30)
        result = rmc.solve_document(document)
        benchmark = result["analytic_benchmark"]
        self.assertAlmostEqual(benchmark["external_blocking_probability"], 8.0 / 15.0)
        self.assertAlmostEqual(benchmark["mean_number_in_system"], 34.0 / 15.0)
        self.assertAlmostEqual(benchmark["utilization"], 14.0 / 15.0)

    def test_unit_importance_tilt_exactly_matches_crude_path(self):
        crude_document = mm1k_document(capacity=6, cycles=500)
        importance_document = copy.deepcopy(crude_document)
        importance_document["rare_event"] = {
            "method": "importance_sampling_mm1k",
            "arrival_rate_multiplier": 1.0,
            "service_rate_multiplier": 1.0,
        }
        crude = rmc.solve_document(crude_document)
        importance = rmc.solve_document(importance_document)

        self.assertEqual(crude["estimates"], importance["estimates"])
        weights = importance["rare_event"]["weight_diagnostics"]
        self.assertEqual(weights["effective_cycles"], 500.0)
        self.assertEqual(weights["log_mean_likelihood_ratio"], 0.0)

    def test_importance_sampling_matches_mm1k_and_reports_weight_ess(self):
        result = rmc.solve_document(load_example("mm1k_importance.json"))
        estimate = result["estimates"]["external_blocking_probability"]
        exact = result["analytic_benchmark"]["external_blocking_probability"]
        weights = result["rare_event"]["weight_diagnostics"]

        self.assertTrue(result["rare_event"]["enabled"])
        self.assertLess(abs(estimate["estimate"] - exact), 3.0 * estimate["standard_error"])
        self.assertGreater(weights["effective_fraction"], 0.25)
        self.assertLess(abs(weights["log_mean_likelihood_ratio"]), 0.15)
        self.assertIn("holding-time factors", result["rare_event"]["likelihood"])

    def test_sequential_precision_uses_alpha_spending(self):
        result = rmc.solve_document(load_example("mm1k_importance.json"))
        precision = result["precision"]
        self.assertTrue(precision["target_met"])
        self.assertEqual(precision["stopping_reason"], "precision_target_met")
        self.assertEqual(
            precision["alpha_spending_rule"],
            "alpha / (metric_count * look * (look + 1))",
        )
        sequential = precision["metrics"]["external_blocking_probability"]
        nominal = result["estimates"]["external_blocking_probability"]["confidence_interval"]
        self.assertGreaterEqual(sequential["sequential_half_width"], nominal["half_width"])


class ValidationAndLimitTests(unittest.TestCase):
    def test_unstable_infinite_buffer_model_is_rejected(self):
        document = load_example("mm1.json")
        document["classes"][0]["external_arrival_rates"]["server"] = 2.0
        with self.assertRaises(rmc.StabilityError) as context:
            rmc.parse_model(document)
        self.assertEqual(context.exception.details["unstable_nodes"][0]["node"], "server")

    def test_closed_routing_class_is_rejected(self):
        document = load_example("mm1.json")
        document["classes"][0]["routing"]["server"] = {"server": 1.0}
        with self.assertRaises(rmc.InputError) as context:
            rmc.parse_model(document)
        self.assertIn("path to exit", str(context.exception))

    def test_importance_sampling_rejects_non_mm1k_scope(self):
        document = load_example("mm1.json")
        document["rare_event"] = {
            "method": "importance_sampling_mm1k",
            "arrival_rate_multiplier": 1.2,
            "service_rate_multiplier": 0.8,
        }
        with self.assertRaises(rmc.InputError) as context:
            rmc.parse_model(document)
        self.assertIn("finite-buffer M/M/1/K", str(context.exception))

    def test_cycle_time_guard_aborts_instead_of_truncating_cycle(self):
        document = mm1k_document(cycles=30)
        document["initial_jobs"] = {"queue": {"jobs": 1}}
        document["stopping"]["maximum_cycle_time"] = 1.0e-12
        with self.assertRaises(rmc.CycleLimitError) as context:
            rmc.solve_document(document)
        self.assertEqual(context.exception.details["stage"], "delayed_first_cycle")
        self.assertEqual(context.exception.details["completed_cycles"], 0)

    def test_maximum_cycles_returns_valid_estimate_without_false_precision_claim(self):
        result = rmc.solve_document(mm1k_document(cycles=30))
        self.assertEqual(result["regeneration"]["complete_cycles"], 30)
        self.assertEqual(result["precision"]["stopping_reason"], "maximum_cycles")
        self.assertFalse(result["precision"]["target_met"])

    def test_total_time_and_event_limits_use_only_complete_cycles(self):
        time_limited = mm1k_document(cycles=30)
        time_limited["stopping"]["maximum_simulated_time"] = 1.0e-12
        result = rmc.solve_document(time_limited)
        self.assertEqual(result["regeneration"]["complete_cycles"], 0)
        self.assertEqual(result["precision"]["stopping_reason"], "maximum_simulated_time")
        self.assertTrue(result["regeneration"]["incomplete_final_cycle_discarded"])
        self.assertFalse(result["estimates"]["mean_number_in_system"]["available"])

        event_limited = mm1k_document(cycles=30)
        event_limited["stopping"]["maximum_events"] = 1
        result = rmc.solve_document(event_limited)
        self.assertEqual(result["regeneration"]["complete_cycles"], 0)
        self.assertEqual(result["precision"]["stopping_reason"], "maximum_events")
        self.assertTrue(result["regeneration"]["incomplete_final_cycle_discarded"])

    def test_cli_supports_json_human_and_structured_error(self):
        document = mm1k_document(cycles=30)
        compact = subprocess.run(
            [sys.executable, str(ROOT / "regenerative_mc.py"), "-", "--compact"],
            input=json.dumps(document),
            text=True,
            capture_output=True,
            check=False,
            cwd=ROOT,
        )
        self.assertEqual(compact.returncode, 0, compact.stderr)
        self.assertEqual(json.loads(compact.stdout)["status"], "ok")

        human = subprocess.run(
            [sys.executable, str(ROOT / "regenerative_mc.py"), "-"],
            input=json.dumps(document),
            text=True,
            capture_output=True,
            check=False,
            cwd=ROOT,
        )
        self.assertEqual(human.returncode, 0, human.stderr)
        self.assertIn("Complete empty-to-empty cycles: 30", human.stdout)
        self.assertIn("not individual events", human.stdout)

        invalid = copy.deepcopy(document)
        invalid["nodes"][0]["service_rate"] = -1.0
        failure = subprocess.run(
            [sys.executable, str(ROOT / "regenerative_mc.py"), "-", "--compact"],
            input=json.dumps(invalid),
            text=True,
            capture_output=True,
            check=False,
            cwd=ROOT,
        )
        self.assertEqual(failure.returncode, 2)
        error = json.loads(failure.stdout)
        self.assertEqual(error["status"], "error")
        self.assertEqual(error["error"]["code"], "invalid_input")

    def test_human_output_has_stable_complete_per_node_metric_records(self):
        document = mm1k_document(cycles=30)
        document["nodes"][0]["id"] = "queue A/=x"
        document["classes"][0]["id"] = "gold jobs=1"
        document["classes"][0]["external_arrival_rates"] = {"queue A/=x": 0.8}
        document["classes"][0]["routing"] = {"queue A/=x": {}}
        result = rmc.solve_document(document)
        lines = rmc._human(result).splitlines()

        # The heading this used to assert ("Per-node metrics
        # (QNET_NODE_METRIC_V1):") is deliberately gone: it announced machine
        # records to a human reader, and the report above now carries the same
        # numbers in a table. What must remain true is that the records are
        # still emitted, still complete, and still last — the parser and the CSV
        # export read them from the tee'd archive.
        self.assertNotIn("Per-node metrics (QNET_NODE_METRIC_V1):", lines)
        records = [line for line in lines if line.startswith("QNET_NODE_METRIC_V1 ")]
        tail = lines[-len(records):]
        self.assertEqual(tail, records, "sentinel records must be the final block")
        self.assertIn("Regenerative Monte Carlo", lines[0])
        self.assertEqual(len(records), 5)
        expected_metrics = [
            "mean_number",
            "mean_queue",
            "utilization",
            "service_completion_rate",
            "mean_number_class",
        ]
        self.assertEqual(
            [record.split()[2].split("=", 1)[1] for record in records],
            expected_metrics,
        )

        expected_field_names = [
            "node_id",
            "metric",
            "class_id",
            "estimate",
            "standard_error",
            "ci_confidence",
            "ci_low",
            "ci_high",
            "ci_half_width",
            "effective_cycles",
        ]
        for index, record in enumerate(records):
            tokens = record.split()
            self.assertEqual(tokens[0], "QNET_NODE_METRIC_V1")
            fields = [token.split("=", 1) for token in tokens[1:]]
            self.assertEqual([name for name, _ in fields], expected_field_names)
            values = dict(fields)
            self.assertEqual(unquote(values["node_id"]), "queue A/=x")
            expected_class = "gold jobs=1" if index == 4 else "-"
            self.assertEqual(unquote(values["class_id"]), expected_class)
            for name in (
                "estimate",
                "standard_error",
                "ci_confidence",
                "ci_low",
                "ci_high",
                "ci_half_width",
                "effective_cycles",
            ):
                self.assertTrue(math.isfinite(float(values[name])))

        # The report comes first, in the shape the other solvers print.
        self.assertTrue(lines[0].startswith("Regenerative Monte Carlo"))
        self.assertTrue(any(line.startswith("Model layer:") for line in lines))
        self.assertTrue(any(line.startswith("Evidence:") for line in lines))

        # These two rows are ResultOutputParser contracts, not decoration:
        # regenerativeCyclesRow and regenerativePrecisionRow match them by
        # regex. Reword either and the Results pane silently loses the cycle
        # count and the precision verdict.
        self.assertTrue(
            any(line.startswith("Complete empty-to-empty cycles:") for line in lines),
            "ResultOutputParser.regenerativeCyclesRow matches this line",
        )
        self.assertTrue(
            any(line.startswith("Precision target met:") for line in lines),
            "ResultOutputParser.regenerativePrecisionRow matches this line",
        )

        # The per-node table replaced the raw records as what a reader sees.
        header = next(line for line in lines if line.startswith("Node "))
        for column in ("E[N]", "E[Q]", "utilisation", "throughput"):
            self.assertIn(column, header)

        # Not ragged: every row of a table is exactly as wide as its rule, so
        # the columns line up. This is the property the fixed-fraction
        # formatting exists to guarantee — the GUI rewrites these numbers to the
        # user's decimal setting and never pads, so a column of uniform-width
        # values is the only thing that survives that rewrite aligned.
        def table_rows(start_label):
            begin = next(i for i, l in enumerate(lines) if l.startswith(start_label))
            rule = lines[begin + 1]
            self.assertTrue(set(rule) == {"-"}, "expected a rule under the header")
            rows = []
            for line in lines[begin + 2:]:
                if not line:
                    break
                rows.append(line)
            return len(rule), rows

        for start_label in ("Node ", "Quantity "):
            width, rows = table_rows(start_label)
            self.assertTrue(rows, "table {!r} has no rows".format(start_label))
            for row in rows:
                self.assertEqual(
                    len(row), width,
                    "row is not flush with its rule in {!r}: {!r}".format(start_label, row),
                )


if __name__ == "__main__":
    unittest.main()
