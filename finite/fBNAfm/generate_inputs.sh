#!/bin/bash
# Generate input files with varying mesh discretization

for n in $(seq 3 15); do
    cat > "../3d_n${n}.in" << EOF
3

1.00000 0.00000 0.00000
0.00000 1.00000 0.00000
0.00000 0.00000 1.00000

1.00000 -1.00000 -0.50000

1 -1 0 -1  1  0
1  1 0 -1 -1  0
0  0 1  0  0 -1

0.00000 0.00000 0.00000
1.00000 1.00000 1.00000
${n} ${n} ${n}
EOF
    echo "Created 3d_n${n}.in"
done
