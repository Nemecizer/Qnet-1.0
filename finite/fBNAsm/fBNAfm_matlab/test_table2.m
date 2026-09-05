% test_table2.m - Reproduce Table 2 from Dai & Harrison (1991)
%
% This tests the SRBM solver for the zero-drift case (mu=0, Gamma=I)
% with the tandem queue reflection matrix.
%
% The paper compares QNET estimates with SCPACK (Trefethen & Williams)
% for various values of the rectangle length parameter a.

clear; clc;

fprintf('=================================================================\n');
fprintf('Reproducing Table 2 from Dai & Harrison (1991)\n');
fprintf('SRBM in Rectangle: Zero Drift Case (mu=0, Gamma=I)\n');
fprintf('=================================================================\n\n');

% Parameters from the paper (Section 5)
% Fixed parameters
b = 1;  % Rectangle height

% Covariance matrix: Gamma = 2*I for the zero-drift case (Section 5 of paper)
% This makes the generator the ordinary Laplacian
Gamma = 2 * eye(2);

% Drift vector (zero for this test)
mu = [0; 0];

% Reflection matrix for tandem queue (equation 24)
% R = [v1 v2 v3 v4] where vi are inward-pointing reflection directions
% v1 corresponds to F1 (x1=0), v2 to F2 (x2=0), v3 to F3 (x1=a), v4 to F4 (x2=b)
R = [1,  0, -1,  1;
    -1,  1,  0, -1];

% Approximation order (paper uses n=6)
n = 6;

% Values of a to test (from Table 2)
a_values = [0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0];

% SCPACK reference values from Table 2 of the paper
% Format: [q1, q2, delta1, delta2, delta3, delta4]
SC_ref = [
    0.258585, 0.380018, 1.871418, 2.412890, 2.412890, 0.541472;  % a=0.5
    0.551506, 0.448494, 0.805295, 1.610589, 1.610589, 0.805295;  % a=1.0
    0.879534, 0.471624, 0.446669, 1.340225, 1.340225, 0.893557;  % a=1.5
    1.239964, 0.482830, 0.270736, 1.206445, 1.206445, 0.935709;  % a=2.0
    1.628342, 0.489146, 0.171214, 1.130587, 1.130587, 0.959373;  % a=2.5
    2.040075, 0.492970, 0.110891, 1.084582, 1.084582, 0.973691;  % a=3.0
    2.471022, 0.495381, 0.072873, 1.055585, 1.055585, 0.982712;  % a=3.5
    2.917572, 0.496936, 0.048334, 1.036868, 1.036868, 0.988534;  % a=4.0
];

% Run the solver and compare
fprintf('Computing QNET estimates with n=%d...\n\n', n);

results = zeros(length(a_values), 6);
for i = 1:length(a_values)
    a = a_values(i);

    [q1, q2, d1, d2, d3, d4] = srbm_2d_solver(a, b, n, Gamma, mu, R);

    results(i, :) = [q1, q2, d1, d2, d3, d4];
end

% Display results in table format similar to paper
fprintf('TABLE 2 COMPARISON: QNET vs SCPACK (n = %d)\n', n);
fprintf('=================================================================\n');
fprintf('%-6s  %-10s %-10s %-10s %-10s %-10s %-10s\n', ...
    'a', 'q1', 'q2', 'delta1', 'delta2', 'delta3', 'delta4');
fprintf('-----------------------------------------------------------------\n');

for i = 1:length(a_values)
    a = a_values(i);

    fprintf('\na = %.1f\n', a);
    fprintf('QNET:  %10.6f %10.6f %10.6f %10.6f %10.6f %10.6f\n', results(i,:));
    fprintf('SC:    %10.6f %10.6f %10.6f %10.6f %10.6f %10.6f\n', SC_ref(i,:));
    fprintf('DIFF:  %10.6f %10.6f %10.6f %10.6f %10.6f %10.6f\n', ...
        results(i,:) - SC_ref(i,:));
end

fprintf('\n=================================================================\n');
fprintf('Summary: Maximum absolute differences from SCPACK\n');
fprintf('=================================================================\n');

diff_matrix = abs(results - SC_ref);
max_diffs = max(diff_matrix, [], 1);
fprintf('Max |diff| for q1:     %.6f\n', max_diffs(1));
fprintf('Max |diff| for q2:     %.6f\n', max_diffs(2));
fprintf('Max |diff| for delta1: %.6f\n', max_diffs(3));
fprintf('Max |diff| for delta2: %.6f\n', max_diffs(4));
fprintf('Max |diff| for delta3: %.6f\n', max_diffs(5));
fprintf('Max |diff| for delta4: %.6f\n', max_diffs(6));

fprintf('\nNote: The paper reports that QNET estimates differ from SC by at most\n');
fprintf('      a few percent for most cases. Small differences are expected.\n');
