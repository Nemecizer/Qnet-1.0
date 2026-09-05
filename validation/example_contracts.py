#!/usr/bin/env python3
"""Validate topology and analytical contracts for tandem example documents."""

from __future__ import annotations

import json
import math
import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
EXAMPLES = ROOT / "input" / "examples"


def rate(node: dict) -> float:
    match = re.search(
        r"(?:^|[,;\s])rate\s*=\s*([0-9.eE+-]+)",
        str(node.get("distributionParameters", "")),
    )
    if not match:
        raise ValueError(f"{node.get('name', node.get('id'))} has no rate parameter")
    value = float(match.group(1))
    if not math.isfinite(value) or value <= 0:
        raise ValueError(f"{node.get('name', node.get('id'))} has invalid rate {value}")
    return value


def validate_tandem(path: pathlib.Path, expected: int, document: dict) -> list[str]:
    problems: list[str] = []
    prefix = path.name
    nodes = document.get("nodes", [])
    links = document.get("links", [])
    if document.get("infiniteBuffers") is not True:
        problems.append(f"{prefix}: must be an infinite-buffer document")
    if not isinstance(nodes, list) or not isinstance(links, list):
        return [f"{prefix}: nodes and links must be arrays"]

    by_kind = {
        kind: [node for node in nodes if node.get("kind") == kind]
        for kind in ("source", "buffer", "station", "sink")
    }
    expected_counts = {
        "source": 1,
        "buffer": expected,
        "station": expected,
        "sink": 1,
    }
    for kind, count in expected_counts.items():
        actual = len(by_kind[kind])
        if actual != count:
            problems.append(
                f"{prefix}: expected {count} {kind} node(s), found {actual}"
            )

    node_ids = [node.get("id") for node in nodes]
    link_ids = [link.get("id") for link in links]
    if any(not isinstance(node_id, str) or not node_id for node_id in node_ids):
        problems.append(f"{prefix}: every node must have a nonempty string id")
    if len(set(node_ids)) != len(node_ids):
        problems.append(f"{prefix}: node ids must be unique")
    if len(set(link_ids)) != len(link_ids) or any(not value for value in link_ids):
        problems.append(f"{prefix}: link ids must be present and unique")
    if len(links) != 2 * expected + 1:
        problems.append(
            f"{prefix}: expected {2 * expected + 1} chain links, found {len(links)}"
        )

    node_by_id = {
        node["id"]: node for node in nodes
        if isinstance(node.get("id"), str) and node.get("id")
    }
    outgoing: dict[str, list[dict]] = {node_id: [] for node_id in node_by_id}
    incoming: dict[str, list[dict]] = {node_id: [] for node_id in node_by_id}
    for link in links:
        origin = link.get("fromNodeID")
        destination = link.get("toNodeID")
        if origin not in node_by_id or destination not in node_by_id:
            problems.append(f"{prefix}: link {link.get('id')} has an unknown endpoint")
            continue
        outgoing[origin].append(link)
        incoming[destination].append(link)
        probability = link.get("routingProbability")
        if not isinstance(probability, (int, float)) or not math.isclose(
            float(probability), 1.0, rel_tol=0.0, abs_tol=1e-12
        ):
            problems.append(
                f"{prefix}: chain link {link.get('id')} must have probability one"
            )
        source_class = link.get("customerClass", 0)
        destination_class = link.get("toCustomerClass", source_class)
        if source_class != 0 or destination_class not in (None, 0):
            problems.append(
                f"{prefix}: chain link {link.get('id')} must preserve class 0"
            )

    if len(by_kind["source"]) == 1 and len(by_kind["sink"]) == 1:
        source = by_kind["source"][0]
        sink = by_kind["sink"][0]
        source_id = source.get("id")
        sink_id = sink.get("id")
        for node_id, node in node_by_id.items():
            want_in = 0 if node_id == source_id else 1
            want_out = 0 if node_id == sink_id else 1
            if len(incoming[node_id]) != want_in or len(outgoing[node_id]) != want_out:
                problems.append(
                    f"{prefix}: {node.get('name')} must have {want_in} incoming "
                    f"and {want_out} outgoing chain link(s)"
                )

        chain: list[dict] = []
        visited: set[str] = set()
        current = source_id
        while current in node_by_id and current not in visited:
            visited.add(current)
            chain.append(node_by_id[current])
            edges = outgoing[current]
            if not edges:
                break
            current = edges[0].get("toNodeID")
        expected_kinds = ["source"]
        for index in range(1, expected + 1):
            expected_kinds += ["buffer", "station"]
        expected_kinds.append("sink")
        actual_kinds = [node.get("kind") for node in chain]
        if actual_kinds != expected_kinds:
            problems.append(f"{prefix}: nodes do not form source→(buffer→station)×N→sink")
        for kind, name_prefix in (("buffer", "B"), ("station", "S")):
            names = [node.get("name") for node in by_kind[kind]]
            if len(set(names)) != len(names) or any(
                not isinstance(name, str) or not name.startswith(name_prefix)
                for name in names
            ):
                problems.append(
                    f"{prefix}: {kind} names must be unique and start with {name_prefix}"
                )
        if len(visited) != len(nodes) or not chain or chain[-1].get("id") != sink_id:
            problems.append(f"{prefix}: tandem path must visit every node exactly once and end at the sink")

        try:
            arrival_rate = rate(source)
            if source.get("distribution") not in ("poisson", "exponential"):
                problems.append(f"{prefix}: source must have a Poisson/exponential arrival clock")
            for station in by_kind["station"]:
                if station.get("distribution") != "exponential":
                    problems.append(f"{prefix}: {station.get('name')} service must be exponential")
                    continue
                if station.get("numberOfServers") != 1:
                    problems.append(f"{prefix}: {station.get('name')} must have one server")
                    continue
                utilization = arrival_rate / rate(station)
                mean_population = utilization / (1.0 - utilization)
                if not math.isclose(utilization, 0.9, rel_tol=2e-7, abs_tol=2e-7):
                    problems.append(
                        f"{prefix}: {station.get('name')} utilization is {utilization}, expected 0.9"
                    )
                if not math.isclose(mean_population, 9.0, rel_tol=2e-6, abs_tol=2e-6):
                    problems.append(
                        f"{prefix}: {station.get('name')} exact E[N] is {mean_population}, expected 9"
                    )
        except (TypeError, ValueError) as error:
            problems.append(f"{prefix}: {error}")
    return problems


def main() -> int:
    failures: list[str] = []
    pattern = re.compile(r"^(\d+)stationtandem\.inf\.bnet$")
    checked = 0
    for path in sorted(EXAMPLES.glob("*stationtandem.inf.bnet")):
        match = pattern.match(path.name)
        if not match:
            continue
        checked += 1
        try:
            document = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            failures.append(f"{path.name}: unreadable JSON: {error}")
            continue
        expected = int(match.group(1))
        failures.extend(validate_tandem(path, expected, document))
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print(
        f"example contracts: {checked} tandem documents passed topology, "
        "routing, load, and exact-mean checks"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
