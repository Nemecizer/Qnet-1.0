#!/bin/bash
#
# Comprehensive Test Script for BNA/FM Algorithm
#
# This script tests the BNA/FM algorithm against numerical results from two papers:
#
# 1. Dai, J.G. and Harrison, J.M. (1991). "Steady-State Analysis of RBM in a Rectangle:
#    Numerical Methods and a Queueing Application." Annals of Applied Probability.
#
# 2. Shen, Chen, Dai, Dai (2000). "The Finite Element Method for Computing the Stationary
#    Distribution of an SRBM in a Hypercube with Applications to Finite Buffer Queueing Networks."
#
# The script:
# - Generates input files for each test case
# - Runs the BNA/FM algorithm
# - Parses the output
# - Compares to expected results from the papers

set -e

# Configuration
BNA_FM_EXECUTABLE="./bna_fm_gauss"
TOLERANCE_PERCENT=5.0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Counters
PASSED=0
FAILED=0
ERRORS=0
TOTAL=0

# Generate input file for 2D case
# Args: gamma11 gamma12 gamma21 gamma22 theta1 theta2 R(flattened) lb1 lb2 ub1 ub2 mesh1 mesh2 output_file
generate_input_2d() {
    local gamma11=$1 gamma12=$2 gamma21=$3 gamma22=$4
    local theta1=$5 theta2=$6
    local r11=$7 r12=$8 r13=$9 r14=${10}
    local r21=${11} r22=${12} r23=${13} r24=${14}
    local lb1=${15} lb2=${16}
    local ub1=${17} ub2=${18}
    local mesh1=${19} mesh2=${20}
    local outfile=${21}

    cat > "$outfile" << EOF
2

$gamma11 $gamma12
$gamma21 $gamma22

$theta1 $theta2

$r11 $r12 $r13 $r14
$r21 $r22 $r23 $r24

$lb1 $lb2
$ub1 $ub2
$mesh1	$mesh2
EOF
}

# Generate input file for 3D case
generate_input_3d() {
    local outfile=$1
    local mesh=$2

    cat > "$outfile" << EOF
3

1.000000 0.000000 0.000000
0.000000 1.000000 0.000000
0.000000 0.000000 1.000000

1.000000 -1.000000 -0.500000

1 -1 0 -1 1 0
1 1 0 -1 -1 0
0 0 1 0 0 -1

0.000000 0.000000 0.000000
1.000000 1.000000 1.000000
$mesh	$mesh	$mesh
EOF
}

# Generate input file for 1D case
generate_input_1d() {
    local outfile=$1

    cat > "$outfile" << EOF
1

2.000000

-1.000000

1 -1

0.000000
1.000000
20
EOF
}

# Run BNA/FM and extract q values
# Args: input_file
# Returns: space-separated q values or "ERROR"
run_bna_fm() {
    local input_file=$1
    local output
    local q_values=""

    if ! output=$("$BNA_FM_EXECUTABLE" "$input_file" 2>&1); then
        echo "ERROR"
        return
    fi

    # Extract q values using grep and sed
    q_values=$(echo "$output" | grep -oE 'q\([0-9]+\)[[:space:]]*=[[:space:]]*[0-9.]+' | sed -E 's/q\([0-9]*\)[[:space:]]*=[[:space:]]*//' | tr '\n' ' ')

    if [ -z "$q_values" ]; then
        echo "ERROR"
        return
    fi

    echo "$q_values"
}

# Compare two floating point numbers with tolerance
# Args: expected actual tolerance_percent
# Returns: 0 if within tolerance, 1 otherwise
compare_float() {
    local expected=$1
    local actual=$2
    local tolerance=$3

    # Use awk for floating point comparison
    awk -v e="$expected" -v act="$actual" -v tol="$tolerance" 'BEGIN {
        if (e == 0) {
            if (act < 0) error = -act * 100
            else error = act * 100
        } else {
            diff = act - e
            if (diff < 0) diff = -diff
            if (e < 0) e = -e
            error = diff / e * 100
        }
        if (error > tol) exit 1
        exit 0
    }'
}

# Calculate error percentage
# Args: expected actual
calc_error() {
    local expected=$1
    local actual=$2

    awk -v e="$expected" -v act="$actual" 'BEGIN {
        if (e == 0 || (e > -0.0000000001 && e < 0.0000000001)) {
            if (act < 0) error = -act * 100
            else error = act * 100
        } else {
            diff = act - e
            if (diff < 0) diff = -diff
            if (e < 0) e = -e
            error = diff / e * 100
        }
        printf "%.2f", error
    }'
}

# Run a single test case
# Args: name paper description dimension expected_q1 [expected_q2] [expected_q3] tolerance input_file
run_test() {
    local name=$1
    local paper=$2
    local description=$3
    local dimension=$4
    local tolerance
    local input_file
    local expected=()

    # Parse expected values based on dimension
    if [ "$dimension" -eq 1 ]; then
        expected=("$5")
        tolerance=$6
        input_file=$7
    elif [ "$dimension" -eq 2 ]; then
        expected=("$5" "$6")
        tolerance=$7
        input_file=$8
    else
        expected=("$5" "$6" "$7")
        tolerance=$8
        input_file=$9
    fi

    TOTAL=$((TOTAL + 1))

    echo "[$TOTAL] $name"
    echo "    Paper: $paper"
    echo "    $description"

    # Run the algorithm
    local result
    result=$(run_bna_fm "$input_file")

    if [ "$result" = "ERROR" ]; then
        echo -e "    Status: ${RED}ERROR${NC} - Could not parse results"
        ERRORS=$((ERRORS + 1))
        echo
        return
    fi

    # Parse result into array
    read -ra computed <<< "$result"

    # Compare results
    local all_passed=true
    local errors=()

    for i in "${!expected[@]}"; do
        local exp="${expected[$i]}"
        local act="${computed[$i]}"
        local err
        err=$(calc_error "$exp" "$act")
        errors+=("$err%")

        if ! compare_float "$exp" "$act" "$tolerance"; then
            all_passed=false
        fi
    done

    # Format computed values
    local computed_str=""
    for v in "${computed[@]}"; do
        computed_str+="$(printf '%.6f' "$v") "
    done

    echo "    Expected: ${expected[*]}"
    echo "    Computed: $computed_str"
    echo "    Errors:   ${errors[*]}"

    if $all_passed; then
        echo -e "    Status:   ${GREEN}PASSED${NC} (tolerance: ${tolerance}%)"
        PASSED=$((PASSED + 1))
    else
        echo -e "    Status:   ${RED}FAILED${NC} (tolerance: ${tolerance}%)"
        FAILED=$((FAILED + 1))
    fi
    echo
}

# Main test function
run_all_tests() {
    echo "================================================================================"
    echo "BNA/FM Algorithm Validation Test Suite"
    echo "Testing against results from Dai-Harrison (1991) and Shen-Chen-Dai-Dai (2000)"
    echo "================================================================================"
    echo

    # Check executable exists
    if [ ! -f "$BNA_FM_EXECUTABLE" ]; then
        echo "ERROR: Executable '$BNA_FM_EXECUTABLE' not found!"
        echo "Please compile the BNA/FM code first."
        exit 1
    fi

    # Create temp directory for input files
    TMPDIR=$(mktemp -d)
    trap 'rm -rf "$TMPDIR"' EXIT

    echo "Running test cases..."
    echo

    # ========================================================================
    # PAPER 1: Dai-Harrison (1991) - Table 2 - 2D SRBM comparison with SCPACK
    # ========================================================================
    # Data: theta = 0, Gamma = 2I, S = [0,a] x [0,1]
    # R = [1, 0, -1, 1; -1, 1, 0, -1]

    # Table 2 data: (a, sc_q1, sc_q2)
    local table2_data=(
        "0.5 0.258585 0.380018"
        "1.0 0.551506 0.448494"
        "1.5 0.879534 0.471624"
        "2.0 1.239964 0.482830"
        "2.5 1.628342 0.489146"
        "3.0 2.040075 0.492970"
        "3.5 2.471022 0.495381"
        "4.0 2.917572 0.496936"
    )

    for entry in "${table2_data[@]}"; do
        read -r a sc_q1 sc_q2 <<< "$entry"
        local input_file="$TMPDIR/dh91_a${a}.in"

        generate_input_2d 2.0 0.0 0.0 2.0 \
                          0.0 0.0 \
                          1 0 -1 1 \
                          -1 1 0 -1 \
                          0.0 0.0 \
                          "$a" 1.0 \
                          9 9 \
                          "$input_file"

        run_test "DH91_Table2_a=$a" \
                 "Dai-Harrison (1991)" \
                 "Table 2: 2D driftless SRBM, a=$a" \
                 2 \
                 "$sc_q1" "$sc_q2" \
                 3.0 \
                 "$input_file"
    done

    # ========================================================================
    # PAPER 2: Shen-Chen-Dai-Dai (2000) - Table 3 - 3D product form solution
    # ========================================================================
    # Exact: q1 = 0.500000, q2 = 0.343482, q3 = 0.418023

    local mesh_sizes=(4 6 8 10)

    for mesh_n in "${mesh_sizes[@]}"; do
        local input_file="$TMPDIR/scdd00_3d_mesh${mesh_n}.in"
        local tol=5.0
        [ "$mesh_n" -ge 6 ] && tol=2.0

        generate_input_3d "$input_file" "$mesh_n"

        run_test "SCDD00_Table3_mesh=$mesh_n" \
                 "Shen-Chen-Dai-Dai (2000)" \
                 "Table 3: 3D product form SRBM, ${mesh_n}x${mesh_n}x${mesh_n} mesh" \
                 3 \
                 0.500000 0.343482 0.418023 \
                 "$tol" \
                 "$input_file"
    done

    # ========================================================================
    # PAPER 2: Table 2 - 2D comparison with SC solution
    # ========================================================================

    local table2_shen=(
        "0.5 0.258548 0.380244"
        "1.0 0.551511 0.448571"
        "1.5 0.879476 0.471676"
        "2.0 1.239767 0.482937"
    )

    for entry in "${table2_shen[@]}"; do
        read -r a fm_q1 fm_q2 <<< "$entry"
        local input_file="$TMPDIR/scdd00_2d_a${a}.in"

        generate_input_2d 2.0 0.0 0.0 2.0 \
                          0.0 0.0 \
                          1 0 -1 1 \
                          -1 1 0 -1 \
                          0.0 0.0 \
                          "$a" 1.0 \
                          8 9 \
                          "$input_file"

        run_test "SCDD00_Table2_a=$a" \
                 "Shen-Chen-Dai-Dai (2000)" \
                 "Table 2: BNA/FM 2D driftless SRBM, a=$a" \
                 2 \
                 "$fm_q1" "$fm_q2" \
                 2.0 \
                 "$input_file"
    done

    # ========================================================================
    # 1D SRBM (two-sided regulated Brownian motion)
    # ========================================================================

    local input_file="$TMPDIR/1d_rbm.in"
    generate_input_1d "$input_file"

    run_test "1D_RegulatedBM" \
             "Harrison (1985) - Analytical" \
             "1D two-sided regulated Brownian motion" \
             1 \
             0.418 \
             5.0 \
             "$input_file"

    # ========================================================================
    # Summary
    # ========================================================================

    echo "================================================================================"
    echo "SUMMARY"
    echo "================================================================================"
    echo "Total tests: $TOTAL"
    echo "Passed:      $PASSED"
    echo "Failed:      $FAILED"
    echo "Errors:      $ERRORS"
    echo

    if [ $FAILED -gt 0 ] || [ $ERRORS -gt 0 ]; then
        echo -e "${RED}Some tests failed or had errors.${NC}"
        return 1
    else
        echo -e "${GREEN}All tests passed!${NC}"
        return 0
    fi
}

# Run tests
run_all_tests
exit $?
