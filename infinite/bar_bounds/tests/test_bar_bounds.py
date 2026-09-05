from __future__ import annotations

import json
import math
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_DIR = Path(__file__).resolve().parents[1]
if str(MODULE_DIR) not in sys.path:
    sys.path.insert(0, str(MODULE_DIR))

from bar_bounds import InputError, build_relaxation, load_model, solve_model


def one_dimensional(**changes):
    document = {
        "schema_version": 1,
        "model_type": "orthant_srbm_bar_bounds",
        "name": "one dimensional test",
        "drift": [-1.0],
        "covariance": [[2.0]],
        "reflection": [[1.0]],
        "relaxation": {
            "order": 2,
            "targets": [
                {"name": "first", "moment": [1]},
                {"name": "second", "moment": [2]},
                {"name": "fourth", "moment": [4]},
            ],
        },
    }
    document.update(changes)
    return document


def product_form():
    return {
        "schema_version": 1,
        "model_type": "orthant_srbm_bar_bounds",
        "name": "two dimensional product form",
        "drift": [-0.75, -0.75],
        "covariance": [[2.0, -0.5], [-0.5, 2.0]],
        "reflection": [[1.0, -0.25], [-0.25, 1.0]],
        "relaxation": {
            "order": 2,
            "targets": [
                {"name": "mean1", "moment": [1, 0]},
                {"name": "mean2", "moment": [0, 1]},
                {"name": "cross", "moment": [1, 1]},
                {"name": "second1", "moment": [2, 0]},
            ],
        },
    }


def general_two_dimensional(order=1):
    return {
        "schema_version": 1,
        "model_type": "orthant_srbm_bar_bounds",
        "name": "general stable test",
        "drift": [-0.84, -0.7],
        "covariance": [[2.0, 0.3], [0.3, 1.5]],
        "reflection": [[1.0, -0.2], [-0.1, 1.0]],
        "relaxation": {
            "order": order,
            "targets": [
                {"name": "mean1", "moment": [1, 0]},
                {"name": "mean2", "moment": [0, 1]},
            ],
        },
    }


class ExactCasesTests(unittest.TestCase):
    def test_one_dimensional_exponential_raw_moments(self):
        model = load_model(one_dimensional())
        result, relaxation = solve_model(model)
        self.assertIsNone(relaxation)
        self.assertEqual(result["method"]["kind"], "exact_one_dimensional_srbm")
        self.assertTrue(result["method"]["certified"])
        self.assertEqual(result["method"]["exponential_rates"], [1.0])
        targets = result["method"]["targets"]
        self.assertEqual(targets["first"]["lower_bound"], 1.0)
        self.assertEqual(targets["second"]["lower_bound"], 2.0)
        self.assertEqual(targets["fourth"]["lower_bound"], 24.0)
        self.assertEqual(targets["fourth"]["lower_bound_exact"], "24")

    def test_one_dimensional_reflection_scaling_only_changes_boundary_mass(self):
        document = one_dimensional(reflection=[[2.0]])
        model = load_model(document)
        result, _ = solve_model(model)
        self.assertEqual(model.boundary_masses, (0.5,))
        self.assertEqual(result["method"]["means"], [1.0])

    def test_one_dimensional_exact_rational_output(self):
        document = one_dimensional(drift=[-3.0])
        model = load_model(document)
        result, _ = solve_model(model)
        targets = result["method"]["targets"]
        self.assertEqual(result["method"]["means_exact"], ["1/3"])
        self.assertEqual(targets["first"]["lower_bound_exact"], "1/3")
        self.assertEqual(targets["second"]["upper_bound_exact"], "2/9")

    def test_nontrivial_skew_symmetric_product_form(self):
        model = load_model(product_form())
        result, relaxation = solve_model(model)
        self.assertIsNone(relaxation)
        method = result["method"]
        self.assertEqual(method["kind"], "exact_skew_symmetric_product_form_srbm")
        self.assertTrue(method["certified"])
        self.assertEqual(list(model.boundary_masses), [1.0, 1.0])
        self.assertEqual(method["means"], [1.0, 1.0])
        self.assertEqual(method["means_exact"], ["1", "1"])
        self.assertEqual(method["targets"]["cross"]["lower_bound"], 1.0)
        self.assertEqual(method["targets"]["second1"]["upper_bound"], 2.0)

    def test_near_skew_symmetry_is_not_called_exact(self):
        document = product_form()
        document["covariance"][0][1] = -0.5000000000001
        document["covariance"][1][0] = -0.5000000000001
        model = load_model(document)
        result, relaxation = solve_model(model)
        self.assertIsNotNone(relaxation)
        self.assertEqual(result["method"]["kind"], "bar_moment_sdp_outer_relaxation")
        skew = result["validation"]["skew_symmetry"]
        self.assertTrue(skew["near_condition"])
        self.assertFalse(skew["exact_for_reported_decimal_parameters"])


class RelaxationTests(unittest.TestCase):
    def setUp(self):
        self.model = load_model(general_two_dimensional(order=1))
        self.ir = build_relaxation(self.model)

    def _variable_names(self):
        return {variable["id"]: variable["name"] for variable in self.ir["variables"]}

    def test_expected_small_cone_dimensions(self):
        counts = self.ir["counts"]
        self.assertEqual(counts["variables"], 12)
        self.assertEqual(counts["equalities"], 10)
        self.assertEqual(counts["psd_blocks"], 7)
        self.assertEqual(counts["largest_psd_block"], 3)
        self.assertEqual(self.ir["maximum_bar_test_degree"], 3)

    def test_degree_one_bar_fixes_boundary_masses_with_column_convention(self):
        self.assertAlmostEqual(self.model.boundary_masses[0], 1.0)
        self.assertAlmostEqual(self.model.boundary_masses[1], 0.8)
        self.assertLess(self.model.validation["boundary_mass_balance_residual"], 1.0e-14)
        self.assertEqual(
            self.ir["reflection_convention"],
            "column i is the reflection direction on face x_i=0",
        )
        names = self._variable_names()
        first_coordinate = next(
            item for item in self.ir["equalities"] if item.get("test_multi_index") == [1, 0]
        )
        coefficients = {
            names[term["variable"]]: term["coefficient"] for term in first_coordinate["terms"]
        }
        self.assertEqual(coefficients, {"y[0,0]": -0.84, "b1[0,0]": 1.0, "b2[0,0]": -0.2})

    def test_bar_for_x1_x2_has_expected_coefficients(self):
        equality = next(
            item for item in self.ir["equalities"] if item.get("test_multi_index") == [1, 1]
        )
        names = self._variable_names()
        coefficients = {names[term["variable"]]: term["coefficient"] for term in equality["terms"]}
        expected = {
            "y[0,0]": 0.3,
            "y[0,1]": -0.84,
            "y[1,0]": -0.7,
            "b1[0,1]": 1.0,
            "b2[1,0]": 1.0,
        }
        self.assertEqual(set(coefficients), set(expected))
        for name, value in expected.items():
            self.assertAlmostEqual(coefficients[name], value)

    def test_boundary_support_is_structural(self):
        boundary_one = [
            variable
            for variable in self.ir["variables"]
            if variable["measure"] == "boundary" and variable["face"] == 0
        ]
        self.assertTrue(boundary_one)
        self.assertTrue(all(variable["multi_index"][0] == 0 for variable in boundary_one))
        self.assertEqual(
            self.ir["support_constraints"]["moments_eliminated_by_boundary_support"], 6
        )

    def test_moment_and_localizing_blocks_use_correct_shifts(self):
        blocks = {block["name"]: block for block in self.ir["psd_blocks"]}
        self.assertEqual(blocks["M_q(interior)"]["basis"], [[0, 0], [0, 1], [1, 0]])
        self.assertEqual(blocks["M_q-1(x1 interior)"]["shift"], [1, 0])
        self.assertEqual(blocks["M_q-1(x2 boundary_face_1)"]["shift"], [0, 1])
        self.assertNotIn("M_q-1(x1 boundary_face_1)", blocks)

    def test_backend_none_constructs_without_claiming_bounds(self):
        result, relaxation = solve_model(self.model, backend="none")
        self.assertIsNotNone(relaxation)
        self.assertFalse(result["method"]["certified"])
        self.assertEqual(result["method"]["targets"]["mean1"]["lower"]["status"], "not_solved")
        self.assertEqual(result["diagnostics"]["backend_status"], "not_requested")

    def test_force_relaxation_overrides_exact_shortcut(self):
        model = load_model(product_form())
        result, relaxation = solve_model(model, force_relaxation=True)
        self.assertIsNotNone(relaxation)
        self.assertEqual(result["method"]["kind"], "bar_moment_sdp_outer_relaxation")

    def test_product_form_moments_satisfy_every_exported_bar_equality(self):
        model = load_model(product_form())
        ir = build_relaxation(model)
        values = {}
        for variable in ir["variables"]:
            alpha = variable["multi_index"]
            moment = 1.0
            for exponent in alpha:
                moment *= math.factorial(exponent)
            if variable["measure"] == "boundary":
                moment *= model.boundary_masses[variable["face"]]
            values[variable["id"]] = moment
        maximum = 0.0
        for equality in ir["equalities"]:
            lhs = sum(term["coefficient"] * values[term["variable"]] for term in equality["terms"])
            maximum = max(maximum, abs(lhs - equality["rhs"]))
        self.assertLess(maximum, 1.0e-12)


class ValidationTests(unittest.TestCase):
    def assertInputError(self, document, phrase):
        with self.assertRaisesRegex(InputError, phrase):
            load_model(document)

    def test_rejects_unstable_drift(self):
        self.assertInputError(one_dimensional(drift=[0.1]), "stability")

    def test_rejects_semidefinite_covariance(self):
        document = general_two_dimensional()
        document["covariance"] = [[1.0, 1.0], [1.0, 1.0]]
        self.assertInputError(document, "positive definite")

    def test_rejects_asymmetric_covariance(self):
        document = general_two_dimensional()
        document["covariance"] = [[2.0, 0.2], [0.3, 1.5]]
        self.assertInputError(document, "symmetric")

    def test_rejects_positive_off_diagonal_reflection(self):
        document = general_two_dimensional()
        document["reflection"] = [[1.0, 0.1], [-0.1, 1.0]]
        self.assertInputError(document, "off-diagonal")

    def test_rejects_z_matrix_that_is_not_nonsingular_m_matrix(self):
        document = general_two_dimensional()
        document["reflection"] = [[1.0, -2.0], [-2.0, 1.0]]
        self.assertInputError(document, "inverse")

    def test_rejects_unknown_fields(self):
        self.assertInputError(one_dimensional(mystery=True), "unknown field")

    def test_rejects_target_beyond_relaxation_degree(self):
        document = one_dimensional()
        document["relaxation"]["targets"] = [{"name": "fifth", "moment": [5]}]
        self.assertInputError(document, "degree 5")

    def test_variable_limit_fails_before_large_construction(self):
        document = general_two_dimensional(order=2)
        document["relaxation"]["max_variables"] = 2
        model = load_model(document)
        with self.assertRaisesRegex(InputError, "scalar moments"):
            build_relaxation(model)

    def test_psd_entry_limit_fails_before_matrix_allocation(self):
        document = general_two_dimensional(order=2)
        document["relaxation"]["max_psd_entries"] = 2
        model = load_model(document)
        with self.assertRaisesRegex(InputError, "PSD matrix entries"):
            build_relaxation(model)


class CommandLineTests(unittest.TestCase):
    def test_require_bounds_rejects_build_only_success(self):
        example = MODULE_DIR / "examples" / "general_two_station.json"
        completed = subprocess.run(
            [
                sys.executable,
                str(MODULE_DIR / "solver.py"),
                str(example),
                "--backend",
                "none",
                "--require-bounds",
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 3)
        self.assertIn("Targets with numerical values: 0/", completed.stdout)
        self.assertIn("no performance bounds were produced", completed.stderr)

    def test_versioned_json_output_and_relaxation_export(self):
        example = MODULE_DIR / "examples" / "general_two_station.json"
        with tempfile.TemporaryDirectory() as directory:
            export = Path(directory) / "relaxation.json"
            completed = subprocess.run(
                [
                    sys.executable,
                    str(MODULE_DIR / "solver.py"),
                    str(example),
                    "--force-relaxation",
                    "--export-relaxation",
                    str(export),
                    "--json",
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            result = json.loads(completed.stdout)
            ir = json.loads(export.read_text(encoding="utf-8"))
        self.assertEqual(result["schema_version"], 1)
        self.assertEqual(result["model_type"], "orthant_srbm_bar_bounds")
        self.assertEqual(ir["ir_schema_version"], 1)
        self.assertEqual(ir["ir_type"], "bar_truncated_stieltjes_moment_sdp")
        self.assertGreater(len(ir["variables"]), 0)

    def test_invalid_cli_backend_choice_exits_two(self):
        example = MODULE_DIR / "examples" / "one_dimensional.json"
        completed = subprocess.run(
            [sys.executable, str(MODULE_DIR / "solver.py"), str(example), "--backend", "invalid"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 2)
        self.assertIn("invalid choice", completed.stderr)


if __name__ == "__main__":
    unittest.main()
