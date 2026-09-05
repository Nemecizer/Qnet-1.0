#!/usr/bin/env python3
"""Command-line entry point for Qnet's exact product-form solvers."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Dict, Mapping, Optional, Sequence

try:  # Package import.
    from .bcmp import parse_bcmp, solve_bcmp
    from .common import (
        ConfigError,
        StateSpaceLimitError,
        integer,
        mapping,
        nonempty_string,
    )
    from .kaufman_roberts import parse_kaufman_roberts, solve_kaufman_roberts
    from .mixed_bcmp import parse_mixed_bcmp, solve_mixed_bcmp
    from .open_bcmp import parse_open_bcmp, solve_open_bcmp
except ImportError:  # Direct script execution.
    from bcmp import parse_bcmp, solve_bcmp
    from common import (
        ConfigError,
        StateSpaceLimitError,
        integer,
        mapping,
        nonempty_string,
    )
    from kaufman_roberts import parse_kaufman_roberts, solve_kaufman_roberts
    from mixed_bcmp import parse_mixed_bcmp, solve_mixed_bcmp
    from open_bcmp import parse_open_bcmp, solve_open_bcmp


def load_document(path: Path) -> Mapping[str, Any]:
    try:
        with path.open("r", encoding="utf-8") as stream:
            document = json.load(stream)
    except OSError as error:
        raise ConfigError("cannot read {}: {}".format(path, error)) from error
    except json.JSONDecodeError as error:
        raise ConfigError(
            "invalid JSON in {} at line {}, column {}: {}".format(
                path, error.lineno, error.colno, error.msg
            )
        ) from error
    return mapping(document, "document")


def solve_document(
    document: Mapping[str, Any], include_states: bool = False
) -> Dict[str, Any]:
    root = mapping(document, "document")
    if "schema_version" not in root:
        raise ConfigError("document is missing required field 'schema_version'")
    version = integer(root["schema_version"], "schema_version", 1)
    if version != 1:
        raise ConfigError("schema_version must be 1")
    if "model_type" not in root:
        raise ConfigError("document is missing required field 'model_type'")
    model_type = nonempty_string(root["model_type"], "model_type")
    if model_type == "closed_bcmp":
        return solve_bcmp(parse_bcmp(root), include_states=include_states)
    if model_type == "open_bcmp":
        if include_states:
            raise ConfigError(
                "open_bcmp has a countably infinite occupancy state space; "
                "--include-states and --top-states are unavailable because the "
                "exact solver does not truncate it"
            )
        return solve_open_bcmp(parse_open_bcmp(root))
    if model_type == "mixed_bcmp":
        return solve_mixed_bcmp(
            parse_mixed_bcmp(root), include_states=include_states
        )
    if model_type == "kaufman_roberts":
        if include_states:
            # The KR result always includes its complete one-dimensional
            # occupancy distribution, so this flag has nothing further to add.
            pass
        return solve_kaufman_roberts(parse_kaufman_roberts(root))
    if model_type in {"mixed_open_closed"}:
        raise ConfigError(
            "model_type={!r} is unsupported; use 'mixed_bcmp'. The exact mixed "
            "subclass and its shared-station boundary are validated explicitly."
            .format(model_type)
        )
    raise ConfigError(
        "unsupported model_type {!r}; expected 'closed_bcmp', 'open_bcmp', "
        "'mixed_bcmp', or 'kaufman_roberts'".format(model_type)
    )


def _optional(value: Any) -> str:
    if value is None:
        return "n/a"
    if isinstance(value, float):
        return "{:.9g}".format(value)
    return str(value)


def print_human(result: Mapping[str, Any], top_states: int = 0) -> None:
    if result["model_type"] == "closed_bcmp":
        solver = result["solver"]
        print("Exact closed BCMP product-form analysis")
        print("Model: {}".format(result["model"]["name"]))
        print(
            "Occupancy states: {}  probability mass: {:.12g}".format(
                solver["state_count"], solver["probability_mass"]
            )
        )
        print(
            "Cross-check residuals: population={:.3e}  throughput={:.3e}".format(
                solver["maximum_population_residual"],
                solver["maximum_throughput_cross_check_residual"],
            )
        )
        for class_result in result["measures"]["classes"]:
            print(
                "Class {id}: N={population}  reference={reference_station}  "
                "X_ref={throughput}  N/X_ref={response}".format(
                    throughput=_optional(class_result["reference_throughput"]),
                    response=_optional(
                        class_result["mean_time_per_reference_visit"]
                    ),
                    **class_result
                )
            )
        for station in result["measures"]["stations"]:
            print(
                "Station {id} ({type}): E[N]={mean_number:.9g}  "
                "throughput={throughput:.9g}  utilization={utilization}".format(
                    utilization=_optional(station["server_utilization"]), **station
                )
            )
            for class_result in station["classes"]:
                if class_result["visit_ratio"] == 0.0:
                    continue
                print(
                    "  Class {class}: visits={visit_ratio:.9g}  "
                    "E[N]={mean_number:.9g}  X={throughput:.9g}  "
                    "R={residence}".format(
                        residence=_optional(
                            class_result["mean_residence_time_per_visit"]
                        ),
                        **class_result
                    )
                )
        if top_states > 0 and "stationary_distribution" in result:
            states = sorted(
                result["stationary_distribution"],
                key=lambda item: item["probability"],
                reverse=True,
            )[:top_states]
            print("Top stationary states:")
            for item in states:
                print("  {:.9g}  {}".format(item["probability"], item["state"]))
        return

    if result["model_type"] == "open_bcmp":
        solver = result["solver"]
        print("Exact open BCMP product-form analysis")
        print("Model: {}".format(result["model"]["name"]))
        print(
            "Analytic probability mass: {:.12g}  minimum stability margin: {}"
            .format(
                solver["probability_mass"],
                _optional(solver["minimum_stability_margin"]),
            )
        )
        print(
            "Cross-check residuals: traffic={:.3e}  flow={:.3e}  Little={:.3e}"
            .format(
                solver["maximum_traffic_equation_residual"],
                solver["maximum_flow_conservation_residual"],
                solver["maximum_little_law_residual"],
            )
        )
        for class_result in result["measures"]["classes"]:
            print(
                "Open class {id}: external={external_arrival_rate:.9g}  "
                "departure={departure_rate:.9g}  E[N]={mean_number:.9g}  "
                "E[T]={mean_time}".format(
                    mean_time=_optional(class_result["mean_time_in_network"]),
                    **class_result
                )
            )
        for station in result["measures"]["stations"]:
            print(
                "Station {id} ({type}): E[N]={mean_number:.9g}  "
                "throughput={throughput:.9g}  utilization={utilization}  "
                "margin={margin}".format(
                    utilization=_optional(station["server_utilization"]),
                    margin=_optional(station["stability_margin"]),
                    **station
                )
            )
        return

    if result["model_type"] == "mixed_bcmp":
        solver = result["solver"]
        print("Exact mixed open/closed BCMP subclass analysis")
        print("Model: {}".format(result["model"]["name"]))
        print("Scope: {}".format(result["model"]["exact_subclass"]))
        print(
            "Closed marginal states: {}  probability mass: {:.12g}  "
            "minimum open stability margin: {}".format(
                solver["closed_marginal_state_count"],
                solver["probability_mass"],
                _optional(solver["minimum_open_stability_margin"]),
            )
        )
        print(
            "Cross-check residuals: traffic={:.3e}  open flow={:.3e}  "
            "closed population={:.3e}  Little={:.3e}".format(
                solver["maximum_open_traffic_equation_residual"],
                solver["maximum_open_flow_conservation_residual"],
                solver["maximum_closed_population_residual"],
                solver["maximum_little_law_residual"],
            )
        )
        for class_result in result["measures"]["open_classes"]:
            print(
                "Open class {id}: external={external_arrival_rate:.9g}  "
                "departure={departure_rate:.9g}  E[N]={mean_number:.9g}  "
                "E[T]={mean_time}".format(
                    mean_time=_optional(class_result["mean_time_in_network"]),
                    **class_result
                )
            )
        for class_result in result["measures"]["closed_classes"]:
            print(
                "Closed class {id}: N={population}  reference={reference_station}  "
                "X_ref={throughput}  N/X_ref={response}".format(
                    throughput=_optional(
                        class_result["reference_throughput"]
                    ),
                    response=_optional(class_result["mean_time_per_reference_visit"]),
                    **class_result
                )
            )
        for station in result["measures"]["stations"]:
            print(
                "Station {id} ({type}): E[N]={mean_number:.9g}  "
                "open={mean_open_number:.9g}  closed={mean_closed_number:.9g}  "
                "utilization={utilization}".format(
                    utilization=_optional(station["server_utilization"]), **station
                )
            )
        if top_states > 0 and "closed_marginal_distribution" in result:
            states = sorted(
                result["closed_marginal_distribution"],
                key=lambda item: item["probability"],
                reverse=True,
            )[:top_states]
            print("Top closed-marginal states:")
            for item in states:
                print(
                    "  {:.9g}  {}".format(
                        item["probability"], item["closed_state"]
                    )
                )
        return

    solver = result["solver"]
    resource = result["measures"]["resource"]
    print("Exact Kaufman-Roberts multi-rate loss analysis")
    print("Model: {}".format(result["model"]["name"]))
    print(
        "Resource {id}: capacity={capacity}  E[occupied]={mean_units_occupied:.9g}  "
        "utilization={utilization:.9g}  P(full)={probability_full:.9g}".format(
            **resource
        )
    )
    print(
        "Occupancy states: {}  conservation residual: {:.3e}".format(
            solver["occupancy_state_count"],
            solver["mean_occupancy_conservation_residual"],
        )
    )
    for class_result in result["measures"]["classes"]:
        print(
            "Class {id}: units={units}  offered={offered_load:.9g}  "
            "blocking={blocking_probability:.9g}  carried={carried_load:.9g}  "
            "loss rate={loss}".format(
                loss=_optional(class_result["loss_rate"]), **class_result
            )
        )


def _argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Solve an exact closed, open, or supported mixed BCMP product "
            "form, or a Kaufman-Roberts multi-rate loss model, from "
            "schema-version 1 JSON."
        )
    )
    parser.add_argument("input", type=Path, help="path to a product-form JSON model")
    parser.add_argument(
        "--json",
        action="store_true",
        dest="json_stdout",
        help="write structured JSON to stdout instead of the human summary",
    )
    parser.add_argument("--output", type=Path, help="also write JSON to this file")
    parser.add_argument(
        "--include-states",
        action="store_true",
        help=(
            "include every closed occupancy state for closed BCMP, or the "
            "finite closed marginal for mixed BCMP; unavailable for open BCMP"
        ),
    )
    parser.add_argument(
        "--top-states",
        type=int,
        default=0,
        help=(
            "show N highest-probability closed or mixed closed-marginal states "
            "in human output"
        ),
    )
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = _argument_parser().parse_args(argv)
    if args.top_states < 0:
        print("error: --top-states must be >= 0", file=sys.stderr)
        return 2
    try:
        document = load_document(args.input)
        include_states = args.include_states or args.top_states > 0
        result = solve_document(document, include_states=include_states)
        serialized = json.dumps(result, indent=2, sort_keys=True, allow_nan=False)
        if args.output is not None:
            try:
                args.output.write_text(serialized + "\n", encoding="utf-8")
            except OSError as error:
                raise ConfigError(
                    "cannot write {}: {}".format(args.output, error)
                ) from error
        if args.json_stdout:
            print(serialized)
        else:
            print_human(result, top_states=args.top_states)
        return 0
    except (ConfigError, StateSpaceLimitError, ValueError, ArithmeticError) as error:
        print("error: {}".format(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
