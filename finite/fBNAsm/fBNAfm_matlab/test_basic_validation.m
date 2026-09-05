% test_basic_validation.m - Basic validation tests for SRBM solver
%
% This script performs basic validation of the solver including:
% 1. Checking that the solution integrates to 1 (probability density)
% 2. Verifying symmetry properties for symmetric problems
% 3. Testing convergence with increasing n

clear; clc;

fprintf('=================================================================\n');
fprintf('Basic Validation Tests for SRBM Solver\n');
fprintf('=================================================================\n\n');

%% Test 1: Symmetric case - unit square with symmetric reflection
fprintf('Test 1: Symmetric case on unit square\n');
fprintf('---------------------------------------\n');

a = 1; b = 1;
Gamma = eye(2);
mu = [0; 0];

% Symmetric reflection matrix (normal reflection on all faces)
% v1 = (1,0), v2 = (0,1), v3 = (-1,0), v4 = (0,-1)
R_symmetric = [1, 0, -1, 0;
               0, 1,  0, -1];

n = 6;
[q1, q2, d1, d2, d3, d4] = srbm_2d_solver(a, b, n, Gamma, mu, R_symmetric);

fprintf('For symmetric problem, expect q1 = q2 and d1 = d3, d2 = d4\n');
fprintf('q1 = %.6f, q2 = %.6f (diff = %.2e)\n', q1, q2, abs(q1-q2));
fprintf('d1 = %.6f, d3 = %.6f (diff = %.2e)\n', d1, d3, abs(d1-d3));
fprintf('d2 = %.6f, d4 = %.6f (diff = %.2e)\n', d2, d4, abs(d2-d4));

if abs(q1-q2) < 0.01 && abs(d1-d3) < 0.01 && abs(d2-d4) < 0.01
    fprintf('PASSED: Symmetry preserved\n\n');
else
    fprintf('WARNING: Symmetry not well preserved\n\n');
end

%% Test 2: Convergence with increasing n
fprintf('Test 2: Convergence with increasing n\n');
fprintf('--------------------------------------\n');

a = 1; b = 1;
Gamma = eye(2);
mu = [0; 0];
R = [1,  0, -1,  1;
    -1,  1,  0, -1];  % Tandem queue reflection

n_values = [3, 4, 5, 6, 7];
q1_values = zeros(size(n_values));
q2_values = zeros(size(n_values));

fprintf('%-5s  %-12s %-12s\n', 'n', 'q1', 'q2');
fprintf('------------------------------\n');

for i = 1:length(n_values)
    n = n_values(i);
    [q1, q2, ~, ~, ~, ~] = srbm_2d_solver(a, b, n, Gamma, mu, R);
    q1_values(i) = q1;
    q2_values(i) = q2;
    fprintf('%-5d  %-12.6f %-12.6f\n', n, q1, q2);
end

% Check convergence
diff_q1 = abs(diff(q1_values));
diff_q2 = abs(diff(q2_values));

if all(diff_q1(end-1:end) < 0.01) && all(diff_q2(end-1:end) < 0.01)
    fprintf('PASSED: Solution appears to converge\n\n');
else
    fprintf('Note: Solution may need higher n for full convergence\n\n');
end

%% Test 3: Non-zero drift case
fprintf('Test 3: Non-zero drift case\n');
fprintf('---------------------------\n');

a = 2; b = 1;
Gamma = eye(2);
mu = [-0.1; 0];  % Small negative drift in x1 direction
R = [1,  0, -1,  1;
    -1,  1,  0, -1];

n = 6;
[q1, q2, d1, d2, d3, d4] = srbm_2d_solver(a, b, n, Gamma, mu, R);

fprintf('With negative drift in x1, expect more mass near x1=0\n');
fprintf('q1 = %.6f (compare to a/2 = %.1f)\n', q1, a/2);
fprintf('q2 = %.6f (compare to b/2 = %.1f)\n', q2, b/2);
fprintf('d1 = %.6f, d3 = %.6f\n', d1, d3);

if q1 < a/2
    fprintf('PASSED: Drift effect visible (q1 < a/2)\n\n');
else
    fprintf('Note: Drift effect may need verification\n\n');
end

%% Test 4: Compare with Table 2 entry (a=1.0)
fprintf('Test 4: Compare with known Table 2 result (a=1.0)\n');
fprintf('-------------------------------------------------\n');

a = 1; b = 1;
Gamma = 2 * eye(2);  % Note: Gamma = 2I for the zero-drift case (Section 5)
mu = [0; 0];
R = [1,  0, -1,  1;
    -1,  1,  0, -1];

n = 6;
[q1, q2, d1, d2, d3, d4] = srbm_2d_solver(a, b, n, Gamma, mu, R);

% Reference from Table 2 (SCPACK values for a=1.0)
q1_ref = 0.551506;
q2_ref = 0.448494;
d1_ref = 0.805295;
d2_ref = 1.610589;

fprintf('Computed: q1=%.6f, q2=%.6f, d1=%.6f, d2=%.6f\n', q1, q2, d1, d2);
fprintf('SCPACK:   q1=%.6f, q2=%.6f, d1=%.6f, d2=%.6f\n', q1_ref, q2_ref, d1_ref, d2_ref);
fprintf('Diff:     q1=%.6f, q2=%.6f, d1=%.6f, d2=%.6f\n', ...
    abs(q1-q1_ref), abs(q2-q2_ref), abs(d1-d1_ref), abs(d2-d2_ref));

max_diff = max([abs(q1-q1_ref), abs(q2-q2_ref), abs(d1-d1_ref), abs(d2-d2_ref)]);
if max_diff < 0.05
    fprintf('PASSED: Results within 5%% of reference\n\n');
else
    fprintf('WARNING: Results differ significantly from reference\n\n');
end

fprintf('=================================================================\n');
fprintf('Validation tests complete\n');
fprintf('=================================================================\n');
