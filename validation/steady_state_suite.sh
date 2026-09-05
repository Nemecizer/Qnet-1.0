#!/usr/bin/env bash
# Deterministic regression gate for the added steady-state methods.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

run() {
    local directory="$1"
    local target="$2"
    printf '\n==> %s (%s)\n' "$directory" "$target"
    make -C "$PROJECT_ROOT/$directory" "$target"
}

run finite/fBNAdecomp test
run finite/fBNAgc test
run infinite/BNAqbd check
run infinite/BNApf check
run infinite/BNAtc check
run infinite/BNAbb check
run infinite/BNArmc check
run infinite/BNAalr check
run infinite/BNAmd check

printf '\n==> Native solver safety contracts\n'
bash "$PROJECT_ROOT/validation/mlmc_native_check.sh"
bash "$PROJECT_ROOT/validation/rqna_integration_check.sh"

printf '\n==> GUI/export/runtime contracts\n'
python3 "$PROJECT_ROOT/validation/example_contracts.py"
bash "$PROJECT_ROOT/validation/result_output_parser_check.sh"
bash "$PROJECT_ROOT/validation/product_form_exporter_check.sh"
bash "$PROJECT_ROOT/validation/qbd_exporter_check.sh"
bash "$PROJECT_ROOT/validation/solver_runtime_resolver_check.sh"
bash "$PROJECT_ROOT/validation/startup_dependency_check.sh"
bash "$PROJECT_ROOT/validation/solver_bundle_audit_check.sh"
bash "$PROJECT_ROOT/validation/gui_runtime_contracts.sh"
bash "$PROJECT_ROOT/validation/embedded_formatter_parse_check.sh"

printf '\nAll added steady-state method checks passed.\n'
