#!/usr/bin/env bash
# Build every maintained native algorithm and validate every Python algorithm
# from the complete source tree. The experimental multiclass diffusion binary
# is optional because it has an additional cJSON dependency.

set -euo pipefail

# Physical paths, not the ones the caller happened to type.
#
# A directory reached through a symlink has two spellings, and Clang records the
# spelling it SAW in each module-cache entry. Build once through
# ~/Library/CloudStorage/Dropbox/... and once through ~/Dropbox/... -- the same
# directory, because macOS makes the second a symlink to the first -- and the
# next compile fails with "module '_DarwinFoundation1' is defined in both", then
# the SDK probe below segfaults and reports a compiler/SDK mismatch that does
# not exist. `pwd -P` collapses the two spellings to one so the cache has a
# single name for each module.
BUILD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$BUILD_ROOT"

fail() {
    printf 'Algorithm build failed: %s\n' "$*" >&2
    exit 1
}

build_native() {
    local directory="$1"
    shift
    printf 'Building %s\n' "$directory"
    make -C "$directory" >/dev/null || fail "make failed in $directory"
    local executable
    for executable in "$@"; do
        [[ -x "$directory/$executable" ]] \
            || fail "$directory/$executable was not produced"
    done
}

# Build the finite hypercube engine before the orthant wrapper that invokes it.
build_native finite/fBNAfm bna_fm_gauss bna_fm_cbc
build_native finite/fBNAlp fBNAlp_solver
build_native finite/fBNAsim fBNAsim
build_native finite/fBNAsm srbm_solver

build_native infinite/BNAqna bna_qna
build_native infinite/BNArqna bna_rqna
build_native infinite/BNAsbd bna_sbd
build_native infinite/BNAsim jackson_sim jackson_sim_finite
build_native infinite/BNAsm bnet
build_native infinite/BNAlp srbm_lp
build_native infinite/BNAmc rbm_mlmc gen_symmetric gen_tridiag
build_native infinite/BNAfm bna_fm

# The C engines for the three methods that ship two implementations. Their
# Makefiles' default target is `engine`, so `make -C` builds only the binary and
# does not run the Python test suites; the parity tests that compare the two
# engines are part of validation/steady_state_suite.sh, not of this script.
#
# These are REQUIRED, not optional. Settings > Solvers > Solver Engine defaults
# to the C engine, and while a missing binary falls back to Python with a note
# in the Status pane, a release that shipped without them would silently be the
# slow one.
build_native infinite/BNArmc bna_rmc
build_native infinite/BNAqbd bna_qbd
build_native infinite/BNAtc bna_tc
build_native finite/fBNAgc fbna_gc

printf 'Checking all Python algorithm sources\n'
python3 - "$BUILD_ROOT" <<'PY'
import ast
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
paths = sorted((*root.joinpath("finite").rglob("*.py"),
                *root.joinpath("infinite").rglob("*.py")))
if not paths:
    raise SystemExit("no Python algorithm sources found")
for path in paths:
    ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
print(f"Validated {len(paths)} Python source files.")
PY

printf 'Building optional multiclass diffusion solver\n'
if make -C infinite/BNAmd solver >/dev/null 2>&1 \
    && [[ -x infinite/BNAmd/mc_solver ]]; then
    printf 'Optional multiclass diffusion solver built successfully.\n'
else
    printf '%s\n' \
        'Optional multiclass diffusion solver skipped: install cjson, suite-sparse, and libomp to enable it.'
fi

printf 'All required algorithm builds passed.\n'
