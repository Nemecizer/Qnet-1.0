#!/usr/bin/env bash
# bench.sh — Run legacy vs. new-formula mc_solver on every .bnet example
# and print a side-by-side comparison.  Also reports published E[X]
# reference values where we have them hand-entered below.

set -u
EXPDIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$EXPDIR/bin/mc_solver"
EXAMPLES="$EXPDIR/../input/examples"
TIMEOUT_SEC="${TIMEOUT_SEC:-90}"

if [[ ! -x "$BIN" ]]; then
    echo "mc_solver not built. Run 'make' in $EXPDIR first." >&2
    exit 1
fi

# Portable timeout: runs "$@" with a wall-clock limit.  On timeout, returns
# exit 124 and leaves no stdout (awk downstream then prints nothing).
run_with_timeout () {
    local secs="$1"; shift
    perl -e '
        use strict; use warnings;
        my $t = shift; my $pid = fork();
        die "fork: $!" unless defined $pid;
        if ($pid == 0) { exec { $ARGV[0] } @ARGV; die "exec: $!"; }
        local $SIG{ALRM} = sub { kill "TERM", $pid; sleep 1; kill "KILL", $pid; exit 124; };
        alarm $t;
        waitpid($pid, 0);
        exit($? >> 8);
    ' "$secs" "$@"
}

run_bnet () {
    local fn="$1" flavor="$2"
    local flag=""
    [[ "$flavor" == "legacy" ]] && flag="--legacy-params"
    # Run compact, extract E[X_i] lines and strip labels.  On timeout or
    # crash, awk still prints a newline so the formatting lines up.
    run_with_timeout "$TIMEOUT_SEC" "$BIN" $flag -c "$fn" 2>/dev/null \
        | awk -F'= *' '/^E\[X_/{printf "%8.4f ", $2} END{print ""}'
}

# Skip list: dimensions we can't run with the direct solver at any
# reasonable mesh size.  Add by basename (no extension).
SKIP=(
    "5stationtandem.inf"
)

should_skip () {
    local b="$1"
    for s in "${SKIP[@]}"; do [[ "$b" == "$s" ]] && return 0; done
    return 1
}

printf "%-40s  %30s  %30s\n" "example" "LEGACY formulas" "NEW formulas"
printf "%-40s  %30s  %30s\n" "-------" "---------------" "------------"
for f in "$EXAMPLES"/*.bnet; do
    base=$(basename "$f" .bnet)
    if should_skip "$base"; then
        printf "%-40s  %30s  %30s\n" "$base" "(skipped: too large)" ""
        continue
    fi
    legacy=$(run_bnet "$f" legacy)
    new=$(run_bnet "$f" new)
    printf "%-40s  %30s  %30s\n" "$base" "$legacy" "$new"
done
