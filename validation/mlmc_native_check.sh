#!/usr/bin/env bash
# Native regression checks for the RBM MLMC argument and sizing preflights.
#
# The production solver uses CXSparse only to create sparse matrices and a
# Cholesky factor.  This check supplies that small ABI in a temporary directory
# so it remains runnable when development CXSparse headers/libraries are absent.

set -euo pipefail

CHECK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_SOURCE="$CHECK_ROOT/infinite/BNAmc/rbm_mlmc.c"
CHECK_CC="${CC:-cc}"
CHECK_SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/qnet-mlmc-native.XXXXXX")"
trap 'rm -rf "$CHECK_SCRATCH"' EXIT

CHECK_INCLUDE="$CHECK_SCRATCH/include"
CHECK_BIN="$CHECK_SCRATCH/rbm_mlmc_check"
CHECK_OUTPUT="$CHECK_SCRATCH/output.txt"
mkdir -p "$CHECK_INCLUDE"
export LC_ALL=C
export BNAMC_SPARSE=1
export BNAMC_SPARSE_R=1

cat > "$CHECK_INCLUDE/cs.h" <<'HEADER'
#ifndef QNET_VALIDATION_CS_H
#define QNET_VALIDATION_CS_H

typedef struct cs_di_sparse {
    int nzmax, m, n;
    int *p, *i;
    double *x;
    int nz;
} cs_di;

typedef struct cs_di_symbolic { int unused; } cs_dis;

typedef struct cs_di_numeric {
    cs_di *L, *U;
    int *pinv;
    double *B;
} cs_din;

cs_di *cs_di_spalloc(int, int, int, int, int);
int cs_di_entry(cs_di *, int, int, double);
cs_di *cs_di_compress(const cs_di *);
cs_di *cs_di_spfree(cs_di *);
cs_dis *cs_di_schol(int, const cs_di *);
cs_dis *cs_di_sfree(cs_dis *);
cs_din *cs_di_chol(const cs_di *, const cs_dis *);
cs_din *cs_di_nfree(cs_din *);

#endif
HEADER

cat > "$CHECK_INCLUDE/omp.h" <<'HEADER'
#ifndef QNET_VALIDATION_OMP_H
#define QNET_VALIDATION_OMP_H
int omp_get_max_threads(void);
#endif
HEADER

cat > "$CHECK_SCRATCH/cs_stub.c" <<'STUB'
#include "cs.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

cs_di *cs_di_spalloc(int m, int n, int nzmax, int values, int triplet)
{
    cs_di *matrix = calloc(1, sizeof(*matrix));
    if (!matrix) return NULL;
    if (nzmax < 1) nzmax = 1;
    matrix->m = m;
    matrix->n = n;
    matrix->nzmax = nzmax;
    matrix->nz = triplet ? 0 : -1;
    matrix->p = calloc((size_t)(triplet ? nzmax : n + 1), sizeof(int));
    matrix->i = calloc((size_t)nzmax, sizeof(int));
    matrix->x = values ? calloc((size_t)nzmax, sizeof(double)) : NULL;
    if (!matrix->p || !matrix->i || (values && !matrix->x))
        return cs_di_spfree(matrix);
    return matrix;
}

int cs_di_entry(cs_di *triplet, int row, int column, double value)
{
    if (!triplet || triplet->nz < 0 || triplet->nz >= triplet->nzmax)
        return 0;
    triplet->i[triplet->nz] = row;
    triplet->p[triplet->nz] = column;
    if (triplet->x) triplet->x[triplet->nz] = value;
    triplet->nz++;
    return 1;
}

cs_di *cs_di_compress(const cs_di *triplet)
{
    if (!triplet || triplet->nz < 0) return NULL;
    cs_di *matrix = cs_di_spalloc(triplet->m, triplet->n, triplet->nz, 1, 0);
    int *next = calloc((size_t)triplet->n, sizeof(int));
    if (!matrix || !next) {
        cs_di_spfree(matrix);
        free(next);
        return NULL;
    }
    for (int entry = 0; entry < triplet->nz; entry++)
        matrix->p[triplet->p[entry] + 1]++;
    for (int column = 0; column < triplet->n; column++) {
        matrix->p[column + 1] += matrix->p[column];
        next[column] = matrix->p[column];
    }
    for (int entry = 0; entry < triplet->nz; entry++) {
        int column = triplet->p[entry];
        int destination = next[column]++;
        matrix->i[destination] = triplet->i[entry];
        matrix->x[destination] = triplet->x ? triplet->x[entry] : 1.0;
    }
    free(next);
    return matrix;
}

cs_di *cs_di_spfree(cs_di *matrix)
{
    if (matrix) {
        free(matrix->p);
        free(matrix->i);
        free(matrix->x);
        free(matrix);
    }
    return NULL;
}

cs_dis *cs_di_schol(int order, const cs_di *matrix)
{
    (void)order;
    return matrix ? calloc(1, sizeof(cs_dis)) : NULL;
}

cs_dis *cs_di_sfree(cs_dis *symbolic)
{
    free(symbolic);
    return NULL;
}

cs_din *cs_di_chol(const cs_di *matrix, const cs_dis *symbolic)
{
    if (!matrix || !symbolic || matrix->m != matrix->n) return NULL;
    int n = matrix->n;
    double *dense = calloc((size_t)n * (size_t)n, sizeof(double));
    double *lower = calloc((size_t)n * (size_t)n, sizeof(double));
    if (!dense || !lower) {
        free(dense);
        free(lower);
        return NULL;
    }

    for (int column = 0; column < n; column++) {
        for (int entry = matrix->p[column]; entry < matrix->p[column + 1]; entry++) {
            int row = matrix->i[entry];
            double value = matrix->x[entry];
            dense[(size_t)row * n + column] = value;
            dense[(size_t)column * n + row] = value;
        }
    }
    for (int row = 0; row < n; row++) {
        for (int column = 0; column <= row; column++) {
            double value = dense[(size_t)row * n + column];
            for (int inner = 0; inner < column; inner++)
                value -= lower[(size_t)row * n + inner] *
                         lower[(size_t)column * n + inner];
            if (row == column) {
                if (!(value > 0.0) || !isfinite(value)) {
                    free(dense);
                    free(lower);
                    return NULL;
                }
                lower[(size_t)row * n + column] = sqrt(value);
            } else {
                lower[(size_t)row * n + column] =
                    value / lower[(size_t)column * n + column];
            }
        }
    }

    cs_din *numeric = calloc(1, sizeof(*numeric));
    cs_di *factor = cs_di_spalloc(n, n, n * (n + 1) / 2, 1, 0);
    if (!numeric || !factor) {
        free(numeric);
        cs_di_spfree(factor);
        free(dense);
        free(lower);
        return NULL;
    }
    int count = 0;
    for (int column = 0; column < n; column++) {
        factor->p[column] = count;
        for (int row = column; row < n; row++) {
            double value = lower[(size_t)row * n + column];
            if (row == column || value != 0.0) {
                factor->i[count] = row;
                factor->x[count] = value;
                count++;
            }
        }
    }
    factor->p[n] = count;
    numeric->L = factor;
    free(dense);
    free(lower);
    return numeric;
}

cs_din *cs_di_nfree(cs_din *numeric)
{
    if (numeric) {
        cs_di_spfree(numeric->L);
        cs_di_spfree(numeric->U);
        free(numeric->pinv);
        free(numeric->B);
        free(numeric);
    }
    return NULL;
}
STUB

cat > "$CHECK_SCRATCH/one.in" <<'INPUT'
1
-1
1
1
INPUT

cat > "$CHECK_SCRATCH/two.in" <<'INPUT'
2
-1 -1
1 0
0 1
1 0
0 1
INPUT

cat > "$CHECK_SCRATCH/too-wide.in" <<'INPUT'
1025
INPUT

compile_flags=(-std=c11 -O0 -Wall -Wextra -Wno-unused-parameter
               -I"$CHECK_INCLUDE")
link_flags=(-lm)
if [[ "$(uname -s)" == "Darwin" ]]; then
    compile_flags+=(-fblocks)
    link_flags=(-framework Accelerate -lm)
else
    compile_flags+=(-D_POSIX_C_SOURCE=200809L)
fi

"$CHECK_CC" "${compile_flags[@]}" -fsyntax-only \
    "$CHECK_SOURCE" "$CHECK_SCRATCH/cs_stub.c"
"$CHECK_CC" "${compile_flags[@]}" -D_OPENMP=201511 -Wno-unknown-pragmas \
    -fsyntax-only "$CHECK_SOURCE" "$CHECK_SCRATCH/cs_stub.c"
"$CHECK_CC" "${compile_flags[@]}" \
    "$CHECK_SOURCE" "$CHECK_SCRATCH/cs_stub.c" \
    -o "$CHECK_BIN" "${link_flags[@]}"

fail() {
    printf 'MLMC native check failed: %s\n' "$*" >&2
    if [[ -s "$CHECK_OUTPUT" ]]; then
        sed 's/^/  | /' "$CHECK_OUTPUT" >&2
    fi
    exit 1
}

expect_ok() {
    local label="$1"
    shift
    if ! "$CHECK_BIN" "$@" >"$CHECK_OUTPUT" 2>&1; then
        fail "$label unexpectedly failed"
    fi
}

expect_fail() {
    local label="$1"
    local expected="$2"
    shift 2
    if "$CHECK_BIN" "$@" >"$CHECK_OUTPUT" 2>&1; then
        fail "$label unexpectedly succeeded"
    fi
    grep -Fq -- "$expected" "$CHECK_OUTPUT" \
        || fail "$label did not report '$expected'"
}

common=("$CHECK_SCRATCH/one.in" 0.5 0.1 --backend serial --threads 1 --seed 1)

expect_ok "one-dimensional automatic L" \
    "${common[@]}" --T 0.5 --N 1
grep -Fq 'L (levels)    = 1' "$CHECK_OUTPUT" \
    || fail "one-dimensional automatic level selection was not L=1"

# L=100 would make the automatic sample calculation vastly exceed INT_MAX,
# while T=1e-25 keeps every possible path counter within range.
expect_ok "explicit --N bypass" \
    "${common[@]}" --T 1e-25 --L 100 --N 1
grep -Fq 'N (samples)   = 1' "$CHECK_OUTPUT" \
    || fail "explicit --N run did not retain its requested sample count"

expect_ok "adaptive cap bypass" \
    "${common[@]}" --T 1e-25 --L 100 --adaptive --batch-size 1 --max-samples 2
grep -Fq 'sample cap    = 2 (--max-samples)' "$CHECK_OUTPUT" \
    || fail "adaptive run did not report its --max-samples cap"

expect_ok "adaptive --N fallback cap" \
    "${common[@]}" --T 1e-25 --L 100 --adaptive --batch-size 1 --N 2
grep -Fq 'sample cap    = 2 (--N fallback)' "$CHECK_OUTPUT" \
    || fail "adaptive run did not use --N as its fallback cap"

expect_ok "adaptive --max-samples precedence" \
    "${common[@]}" --T 1e-25 --L 100 --adaptive --batch-size 1 \
    --max-samples 2 --N 3
grep -Fq 'Note: --max-samples controls adaptive sampling; --N is ignored.' \
    "$CHECK_OUTPUT" \
    || fail "adaptive --max-samples did not explicitly take precedence over --N"

# This default floor is just above INT_MAX.  The historical int multiplication
# wrapped and could falsely declare convergence after two zero-variance draws.
expect_ok "adaptive default floor arithmetic" \
    "${common[@]}" --T 0.5 --L 1 --adaptive \
    --batch-size 429496730 --max-samples 2
grep -Fq 'stop=hit --max-samples cap' "$CHECK_OUTPUT" \
    || fail "large adaptive batch wrapped its minimum-sample floor"

expect_fail "automatic N overflow" 'automatic sample count is outside' \
    "${common[@]}" --T 1e-25 --L 100

expect_fail "path-step overflow despite explicit N" \
    'maximum fine path step count is outside' \
    "${common[@]}" --T 0.01 --L 39 --N 1

expect_fail "non-finite gamma" "Invalid gamma value: 'NaN'" \
    "$CHECK_SCRATCH/one.in" NaN 0.1
expect_fail "malformed integer" "Invalid --N value '1junk'" \
    "${common[@]}" --N 1junk
expect_fail "missing adaptive cap" '--adaptive requires a positive --max-samples cap' \
    "${common[@]}" --T 0.5 --L 1 --adaptive --batch-size 1
expect_fail "one-sample adaptive cap" 'adaptive sample cap must be at least 2' \
    "${common[@]}" --T 0.5 --L 1 --adaptive --batch-size 1 --max-samples 1
expect_fail "dimension bound" "expected 1..1024" \
    "$CHECK_SCRATCH/too-wide.in" 0.5 0.1 --backend serial --N 1

expect_ok "point-only component average" \
    "$CHECK_SCRATCH/two.in" 0.5 0.1 --backend serial --seed 1 \
    --T 0.5 --L 1 --N 2
average_line="$(grep -F '# Average across all components:' "$CHECK_OUTPUT" || true)"
[[ "$average_line" == *'point estimate only'* ]] \
    || fail "native component average was not labelled point-only"
[[ "$average_line" != *'(SE '* ]] \
    || fail "native component average still reports a covariance-blind SE"

grep -Eq 'schedule[[:space:]]*\([[:space:]]*dynamic' "$CHECK_SOURCE" \
    && fail "OpenMP sampling reverted to dynamic scheduling"
grep -Fq 'atomic_int sample_ctr' "$CHECK_SOURCE" \
    && fail "GCD sampling reverted to an atomic work queue"

check_parallel_repeatability() {
    local executable="$1"
    local backend="$2"
    local label="$3"
    local first="$CHECK_SCRATCH/${label}-fixed-first.txt"
    local second="$CHECK_SCRATCH/${label}-fixed-second.txt"
    local adaptive="$CHECK_SCRATCH/${label}-adaptive.txt"
    local adaptive_second="$CHECK_SCRATCH/${label}-adaptive-second.txt"
    local different="$CHECK_SCRATCH/${label}-different-seed.txt"
    local first_normalized="$CHECK_SCRATCH/${label}-fixed-first-normalized.txt"
    local second_normalized="$CHECK_SCRATCH/${label}-fixed-second-normalized.txt"
    local first_stderr="$CHECK_SCRATCH/${label}-fixed-first.stderr"
    local second_stderr="$CHECK_SCRATCH/${label}-fixed-second.stderr"
    local adaptive_stderr="$CHECK_SCRATCH/${label}-adaptive.stderr"
    local adaptive_second_stderr="$CHECK_SCRATCH/${label}-adaptive-second.stderr"
    local different_stderr="$CHECK_SCRATCH/${label}-different-seed.stderr"
    local fixed_fingerprint="$CHECK_SCRATCH/${label}-fixed.fingerprint"
    local adaptive_fingerprint="$CHECK_SCRATCH/${label}-adaptive.fingerprint"
    local adaptive_second_fingerprint="$CHECK_SCRATCH/${label}-adaptive-second.fingerprint"
    local different_fingerprint="$CHECK_SCRATCH/${label}-different-seed.fingerprint"
    local fixed_args=("$CHECK_SCRATCH/two.in" 0.5 0.1 --backend "$backend"
                      --threads 3 --seed 2468 --T 0.5 --L 2 --N 11)
    local adaptive_args=("$CHECK_SCRATCH/two.in" 0.5 0.1 --backend "$backend"
                         --threads 3 --seed 2468 --T 0.5 --L 2 --adaptive
                         --batch-size 4 --min-samples 11 --max-samples 11)
    local different_args=("$CHECK_SCRATCH/two.in" 0.5 0.1 --backend "$backend"
                          --threads 3 --seed 8642 --T 0.5 --L 2 --N 11)

    "$executable" "${fixed_args[@]}" >"$first" 2>"$first_stderr" \
        || { CHECK_OUTPUT="$first_stderr"; fail "$label first run failed"; }
    "$executable" "${fixed_args[@]}" >"$second" 2>"$second_stderr" \
        || { CHECK_OUTPUT="$second_stderr"; fail "$label second run failed"; }
    "$executable" "${adaptive_args[@]}" >"$adaptive" 2>"$adaptive_stderr" \
        || { CHECK_OUTPUT="$adaptive_stderr"; fail "$label adaptive run failed"; }
    "$executable" "${adaptive_args[@]}" >"$adaptive_second" 2>"$adaptive_second_stderr" \
        || { CHECK_OUTPUT="$adaptive_second_stderr"; fail "$label second adaptive run failed"; }
    "$executable" "${different_args[@]}" >"$different" 2>"$different_stderr" \
        || { CHECK_OUTPUT="$different_stderr"; fail "$label different-seed run failed"; }

    grep -Fq "backend       = $backend" "$first_stderr" \
        || { CHECK_OUTPUT="$first_stderr"; fail "$label backend was not active"; }
    grep -Fq 'threads       = 3' "$first_stderr" \
        || { CHECK_OUTPUT="$first_stderr"; fail "$label did not use three workers"; }
    grep -Eq '^# gamma=.* L=2  N=11  seed=2468$' "$first" \
        || { CHECK_OUTPUT="$first"; fail "$label fixed run did not process 11 samples"; }
    grep -Eq '^# gamma=.* L=2  N=11  seed=2468$' "$adaptive" \
        || { CHECK_OUTPUT="$adaptive"; fail "$label adaptive run did not process 11 samples"; }

    # Wall time is expected to vary; every numerical/result line must match.
    grep -v '^# backend=' "$first" >"$first_normalized"
    grep -v '^# backend=' "$second" >"$second_normalized"
    if ! cmp -s "$first_normalized" "$second_normalized"; then
        diff -u "$first_normalized" "$second_normalized" >&2 || true
        CHECK_OUTPUT="$first"
        fail "$label changed numerical output for a fixed seed"
    fi

    # Fixed and 4+4+3 adaptive dispatches must consume the same logical RNG
    # lanes, while another seed must genuinely change the sampled result.
    grep -E '^(# Total Gaussian RVs generated:|[[:space:]]+[0-9]+[[:space:]]|E\[X_[0-9]+\])' \
        "$first" >"$fixed_fingerprint"
    grep -E '^(# Total Gaussian RVs generated:|[[:space:]]+[0-9]+[[:space:]]|E\[X_[0-9]+\])' \
        "$adaptive" >"$adaptive_fingerprint"
    grep -E '^(# Total Gaussian RVs generated:|[[:space:]]+[0-9]+[[:space:]]|E\[X_[0-9]+\])' \
        "$adaptive_second" >"$adaptive_second_fingerprint"
    grep -E '^(# Total Gaussian RVs generated:|[[:space:]]+[0-9]+[[:space:]]|E\[X_[0-9]+\])' \
        "$different" >"$different_fingerprint"
    cmp -s "$fixed_fingerprint" "$adaptive_fingerprint" \
        || { CHECK_OUTPUT="$adaptive"; fail "$label fixed/adaptive RNG lanes differ"; }
    cmp -s "$adaptive_fingerprint" "$adaptive_second_fingerprint" \
        || { CHECK_OUTPUT="$adaptive_second"; fail "$label adaptive output is not repeatable"; }
    if cmp -s "$fixed_fingerprint" "$different_fingerprint"; then
        CHECK_OUTPUT="$different"
        fail "$label repeatability fixture does not distinguish different seeds"
    fi
}

if [[ "$(uname -s)" == "Darwin" ]]; then
    check_parallel_repeatability "$CHECK_BIN" accelerate gcd
    openmp_prefix="${LIBOMP_PREFIX:-}"
    if [[ -z "$openmp_prefix" ]] && command -v brew >/dev/null 2>&1; then
        openmp_prefix="$(brew --prefix libomp 2>/dev/null || true)"
    fi
    if [[ -n "$openmp_prefix" &&
          ( -f "$openmp_prefix/lib/libomp.dylib" ||
            -f "$openmp_prefix/lib/libomp.a" ) ]]; then
        openmp_bin="$CHECK_SCRATCH/rbm_mlmc_openmp_check"
        if "$CHECK_CC" "${compile_flags[@]}" -Xpreprocessor -fopenmp \
            "$CHECK_SOURCE" "$CHECK_SCRATCH/cs_stub.c" \
            -o "$openmp_bin" -L"$openmp_prefix/lib" -lomp \
            -Wl,-rpath,"$openmp_prefix/lib" \
            "${link_flags[@]}" >"$CHECK_SCRATCH/openmp-build.log" 2>&1; then
            check_parallel_repeatability "$openmp_bin" openmp openmp
        else
            printf 'OpenMP build unavailable; static assignment source checks passed.\n'
        fi
    else
        printf 'OpenMP runtime unavailable; static assignment source checks passed.\n'
    fi
else
    openmp_bin="$CHECK_SCRATCH/rbm_mlmc_openmp_check"
    if "$CHECK_CC" "${compile_flags[@]}" -fopenmp \
        "$CHECK_SOURCE" "$CHECK_SCRATCH/cs_stub.c" \
        -o "$openmp_bin" -lm >"$CHECK_SCRATCH/openmp-build.log" 2>&1; then
        check_parallel_repeatability "$openmp_bin" openmp openmp
    else
        printf 'OpenMP runtime unavailable; static assignment source checks passed.\n'
    fi
fi

printf 'MLMC native safety checks passed.\n'
