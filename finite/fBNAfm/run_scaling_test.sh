#!/bin/bash
# Scaling test for BNA/FM algorithm
# Tests discretization from n=3 to n=15

# Expected values for comparison (from reference)
Q1_EXPECTED=0.500000
Q2_EXPECTED=0.343482
Q3_EXPECTED=0.418023

# Output file for results
RESULTS_FILE="scaling_results.csv"

echo "=========================================="
echo "BNA/FM Scaling Test"
echo "=========================================="
echo ""

# Generate input files first
echo "Generating input files..."
./generate_inputs.sh
echo ""

# Header for CSV
echo "n,n_basis,nnz,time_gauss,time_cbc,q1_gauss,q2_gauss,q3_gauss,q1_cbc,q2_cbc,q3_cbc,err_gauss,err_cbc" > $RESULTS_FILE

# Print header for console
printf "%-4s | %-8s | %-10s | %-10s | %-10s | %-22s | %-22s | %-10s | %-10s\n" \
       "n" "n_basis" "nnz" "T_Gauss" "T_CBC" "q_Gauss" "q_CBC" "Err_Gauss" "Err_CBC"
printf "%s\n" "-----+----------+------------+------------+------------+------------------------+------------------------+------------+------------"

for n in $(seq 3 15); do
    INPUT_FILE="../3d_n${n}.in"

    # Run Gaussian version and capture output
    GAUSS_OUTPUT=$(./bna_fm_gauss "$INPUT_FILE" 2>&1)

    # Extract values from Gaussian output
    N_BASIS=$(echo "$GAUSS_OUTPUT" | grep "Number of basis" | awk '{print $NF}')
    NNZ=$(echo "$GAUSS_OUTPUT" | grep "nnz =" | awk '{print $NF}')
    TIME_GAUSS=$(echo "$GAUSS_OUTPUT" | grep "Total time:" | awk '{print $3}')
    Q1_GAUSS=$(echo "$GAUSS_OUTPUT" | grep "q(1)" | awk '{print $3}')
    Q2_GAUSS=$(echo "$GAUSS_OUTPUT" | grep "q(2)" | awk '{print $3}')
    Q3_GAUSS=$(echo "$GAUSS_OUTPUT" | grep "q(3)" | awk '{print $3}')

    # Run CBC version and capture output
    CBC_OUTPUT=$(./bna_fm_cbc "$INPUT_FILE" 256 2>&1)

    # Extract values from CBC output
    TIME_CBC=$(echo "$CBC_OUTPUT" | grep "Total time:" | awk '{print $3}')
    Q1_CBC=$(echo "$CBC_OUTPUT" | grep "q(1)" | awk '{print $3}')
    Q2_CBC=$(echo "$CBC_OUTPUT" | grep "q(2)" | awk '{print $3}')
    Q3_CBC=$(echo "$CBC_OUTPUT" | grep "q(3)" | awk '{print $3}')

    # Calculate L2 errors
    ERR_GAUSS=$(echo "scale=8; sqrt(($Q1_GAUSS - $Q1_EXPECTED)^2 + ($Q2_GAUSS - $Q2_EXPECTED)^2 + ($Q3_GAUSS - $Q3_EXPECTED)^2)" | bc -l)
    ERR_CBC=$(echo "scale=8; sqrt(($Q1_CBC - $Q1_EXPECTED)^2 + ($Q2_CBC - $Q2_EXPECTED)^2 + ($Q3_CBC - $Q3_EXPECTED)^2)" | bc -l)

    # Format q values for display
    Q_GAUSS_STR=$(printf "%.4f, %.4f, %.4f" $Q1_GAUSS $Q2_GAUSS $Q3_GAUSS)
    Q_CBC_STR=$(printf "%.4f, %.4f, %.4f" $Q1_CBC $Q2_CBC $Q3_CBC)

    # Print to console
    printf "%-4d | %-8s | %-10s | %-10s | %-10s | %-22s | %-22s | %-10.6f | %-10.6f\n" \
           $n "$N_BASIS" "$NNZ" "${TIME_GAUSS}s" "${TIME_CBC}s" "$Q_GAUSS_STR" "$Q_CBC_STR" $ERR_GAUSS $ERR_CBC

    # Save to CSV
    echo "$n,$N_BASIS,$NNZ,$TIME_GAUSS,$TIME_CBC,$Q1_GAUSS,$Q2_GAUSS,$Q3_GAUSS,$Q1_CBC,$Q2_CBC,$Q3_CBC,$ERR_GAUSS,$ERR_CBC" >> $RESULTS_FILE
done

echo ""
echo "=========================================="
echo "Expected values: q = ($Q1_EXPECTED, $Q2_EXPECTED, $Q3_EXPECTED)"
echo "=========================================="
echo ""
echo "Results saved to: $RESULTS_FILE"
echo ""

# Summary statistics
echo "=========================================="
echo "Summary Analysis"
echo "=========================================="

# Extract first and last errors for comparison
FIRST_ERR_GAUSS=$(sed -n '2p' $RESULTS_FILE | cut -d',' -f12)
LAST_ERR_GAUSS=$(tail -1 $RESULTS_FILE | cut -d',' -f12)
FIRST_ERR_CBC=$(sed -n '2p' $RESULTS_FILE | cut -d',' -f13)
LAST_ERR_CBC=$(tail -1 $RESULTS_FILE | cut -d',' -f13)

FIRST_TIME_GAUSS=$(sed -n '2p' $RESULTS_FILE | cut -d',' -f4)
LAST_TIME_GAUSS=$(tail -1 $RESULTS_FILE | cut -d',' -f4)
FIRST_TIME_CBC=$(sed -n '2p' $RESULTS_FILE | cut -d',' -f5)
LAST_TIME_CBC=$(tail -1 $RESULTS_FILE | cut -d',' -f5)

echo ""
echo "Gaussian Quadrature:"
echo "  Error reduction: $FIRST_ERR_GAUSS -> $LAST_ERR_GAUSS"
echo "  Time increase:   ${FIRST_TIME_GAUSS}s -> ${LAST_TIME_GAUSS}s"
echo ""
echo "CBC-QMC:"
echo "  Error reduction: $FIRST_ERR_CBC -> $LAST_ERR_CBC"
echo "  Time increase:   ${FIRST_TIME_CBC}s -> ${LAST_TIME_CBC}s"
