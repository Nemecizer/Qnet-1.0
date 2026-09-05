"""MVA is checked against the enumerating solver, not against itself.

`bcmp.solve_bcmp` builds every feasible population state and normalises. It is
slow, but it is independent code arriving at the same product form by a
different route, so agreement between the two is a genuine cross-check rather
than a restatement. Every model here is small enough to enumerate; the point of
MVA is the models that are not, and those are covered by the scaling test at the
bottom, which only asserts what can be asserted without an oracle.
"""

import math
import pathlib
import sys
import unittest

MODULE_DIR = pathlib.Path(__file__).resolve().parents[1]
if str(MODULE_DIR.parent) not in sys.path:
    sys.path.insert(0, str(MODULE_DIR.parent))

from BNApf.bcmp import parse_bcmp, solve_bcmp, state_count  # noqa: E402
from BNApf.common import StateSpaceLimitError  # noqa: E402
from BNApf.mva import lattice_size, solve_mva  # noqa: E402

TOLERANCE = 1e-9


def document(stations, classes, name="test", max_states=1_000_000):
    """Build a closed_bcmp document from compact positional test data.

    `stations` entries are (id, type, servers, [service time per class]) and
    `classes` entries are (id, population, [visit ratio per station]); the
    document form keys both by id, which is unreadable in a table.
    A service time or visit ratio of None/0 means that class does not use that
    station.
    """
    class_ids = [c[0] for c in classes]
    station_ids = [s[0] for s in stations]
    station_objs = []
    for (sid, stype, servers, times) in stations:
        obj = {
            "id": sid,
            "type": stype,
            "service_times": {
                cid: t for cid, t in zip(class_ids, times) if t is not None
            },
        }
        if servers is not None:
            obj["servers"] = servers
        station_objs.append(obj)
    class_objs = []
    for (cid, population, visits) in classes:
        used = {sid: v for sid, v in zip(station_ids, visits) if v}
        class_objs.append({
            "id": cid,
            "population": population,
            "reference_station": next(iter(used)) if used else station_ids[0],
            "visit_ratios": used,
        })
    return {
        "schema_version": 1,
        "model_type": "closed_bcmp",
        "name": name,
        "stations": station_objs,
        "classes": class_objs,
        "solver": {"max_states": max_states},
    }


class MVAAgreesWithEnumeration(unittest.TestCase):
    def assert_agrees(self, doc):
        model = parse_bcmp(doc)
        exact = solve_bcmp(model)["measures"]
        mva = solve_mva(model)["measures"]

        for station_exact, station_mva in zip(exact["stations"], mva["stations"]):
            self.assertEqual(station_exact["id"], station_mva["id"])
            self.assertAlmostEqual(
                station_exact["mean_number"], station_mva["mean_number"],
                delta=TOLERANCE,
                msg="mean number at {}".format(station_exact["id"]),
            )
            self.assertAlmostEqual(
                station_exact["throughput"], station_mva["throughput"],
                delta=TOLERANCE,
                msg="throughput at {}".format(station_exact["id"]),
            )
            if (
                station_exact["server_utilization"] is not None
                and station_mva["server_utilization"] is not None
            ):
                self.assertAlmostEqual(
                    station_exact["server_utilization"],
                    station_mva["server_utilization"],
                    delta=TOLERANCE,
                    msg="utilisation at {}".format(station_exact["id"]),
                )
            for class_exact, class_mva in zip(
                station_exact["classes"], station_mva["classes"]
            ):
                self.assertAlmostEqual(
                    class_exact["mean_number"], class_mva["mean_number"],
                    delta=TOLERANCE,
                    msg="mean number {} / {}".format(
                        station_exact["id"], class_exact["class"]
                    ),
                )
                self.assertAlmostEqual(
                    class_exact["throughput"], class_mva["throughput"],
                    delta=TOLERANCE,
                    msg="throughput {} / {}".format(
                        station_exact["id"], class_exact["class"]
                    ),
                )
        return exact, mva

    def test_single_class_two_stations(self):
        self.assert_agrees(document(
            stations=[("cpu", "processor_sharing", None, [0.5]),
                      ("disk", "processor_sharing", None, [0.3])],
            classes=[("jobs", 6, [1.0, 2.0])],
        ))

    def test_delay_station(self):
        self.assert_agrees(document(
            stations=[("cpu", "processor_sharing", None, [0.4]),
                      ("think", "infinite_server", None, [2.0])],
            classes=[("users", 8, [1.0, 1.0])],
        ))

    def test_fcfs_single_server(self):
        self.assert_agrees(document(
            stations=[("a", "fcfs", 1, [0.6]),
                      ("b", "fcfs", 1, [0.25])],
            classes=[("jobs", 5, [1.0, 1.5])],
        ))

    def test_fcfs_multi_server_is_load_dependent(self):
        """The case the load-dependent recursion exists for."""
        self.assert_agrees(document(
            stations=[("pool", "fcfs", 3, [0.9]),
                      ("disk", "fcfs", 1, [0.4])],
            classes=[("jobs", 7, [1.0, 1.0])],
        ))

    def test_multiclass(self):
        self.assert_agrees(document(
            stations=[("cpu", "processor_sharing", None, [0.3, 0.7]),
                      ("disk", "processor_sharing", None, [0.5, 0.2]),
                      ("think", "infinite_server", None, [1.0, 4.0])],
            classes=[("batch", 3, [1.0, 2.0, 1.0]),
                     ("inter", 4, [1.0, 0.5, 1.0])],
        ))

    def test_multiclass_with_multi_server(self):
        self.assert_agrees(document(
            stations=[("pool", "fcfs", 2, [0.5, 0.5]),
                      ("cpu", "processor_sharing", None, [0.4, 0.6])],
            classes=[("x", 3, [1.0, 1.0]),
                     ("y", 2, [1.0, 2.0])],
        ))

    def test_class_that_skips_a_station(self):
        self.assert_agrees(document(
            stations=[("shared", "processor_sharing", None, [0.4, 0.4]),
                      ("private", "processor_sharing", None, [0.9, None])],
            classes=[("uses_both", 3, [1.0, 1.0]),
                     ("shared_only", 3, [1.0, 0.0])],
        ))

    def test_zero_population_class(self):
        self.assert_agrees(document(
            stations=[("a", "processor_sharing", None, [0.5, 0.5]),
                      ("b", "processor_sharing", None, [0.5, 0.5])],
            classes=[("active", 4, [1.0, 1.0]),
                     ("idle", 0, [1.0, 1.0])],
        ))


class MVAScalesPastEnumeration(unittest.TestCase):
    """No oracle here — enumeration cannot reach these — so assert only
    what is checkable without one: conservation, Little's law, and the
    asymptote a closed network must approach."""

    def test_population_far_beyond_the_state_guard(self):
        doc = document(
            stations=[("cpu", "processor_sharing", None, [0.20]),
                      ("d1", "processor_sharing", None, [0.10]),
                      ("d2", "processor_sharing", None, [0.05]),
                      ("d3", "processor_sharing", None, [0.05]),
                      ("d4", "processor_sharing", None, [0.05]),
                      ("think", "infinite_server", None, [5.0])],
            classes=[("jobs", 400, [1.0, 0.5, 0.3, 0.1, 0.1, 1.0])],
        )
        model = parse_bcmp(doc)

        # Enumeration is not merely slow here — state_count refuses outright.
        with self.assertRaises(StateSpaceLimitError):
            state_count(model)
        self.assertEqual(lattice_size(model), 401)

        result = solve_mva(model)
        diagnostics = result["diagnostics"]
        self.assertLess(diagnostics["population_conservation_residual"], 1e-6)
        self.assertLess(diagnostics["littles_law_residual"], 1e-6)

        # Every mean is finite and non-negative, and the populations add up.
        total = math.fsum(s["mean_number"] for s in result["measures"]["stations"])
        self.assertAlmostEqual(total, 400.0, delta=1e-6)
        for station in result["measures"]["stations"]:
            self.assertGreaterEqual(station["mean_number"], -1e-12)
            self.assertTrue(math.isfinite(station["mean_number"]))

        # At population 400 the bottleneck (highest demand: cpu, D = 0.20)
        # must be saturated and must hold most of the jobs.
        cpu = next(s for s in result["measures"]["stations"] if s["id"] == "cpu")
        self.assertGreater(cpu["server_utilization"], 0.99)
        self.assertGreater(cpu["mean_number"], 300.0)

        # Throughput is bounded by the bottleneck: X <= 1 / D_max.
        jobs = result["measures"]["classes"][0]
        self.assertLessEqual(jobs["reference_throughput"], 1.0 / 0.20 + 1e-9)

    def test_throughput_is_monotone_in_population(self):
        """A closed product-form network's throughput increases with N and
        approaches the bottleneck rate from below."""
        previous = 0.0
        for population in (1, 2, 5, 10, 25, 50, 100, 200):
            doc = document(
                stations=[("cpu", "processor_sharing", None, [0.25]),
                          ("disk", "processor_sharing", None, [0.10])],
                classes=[("jobs", population, [1.0, 1.0])],
            )
            throughput = solve_mva(parse_bcmp(doc))["measures"]["classes"][0]["reference_throughput"]
            self.assertGreater(throughput, previous - 1e-12)
            self.assertLessEqual(throughput, 1.0 / 0.25 + 1e-9)
            previous = throughput
        self.assertAlmostEqual(previous, 4.0, delta=0.05)


if __name__ == "__main__":
    unittest.main()
