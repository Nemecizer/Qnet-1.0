% test_table3_iteration.m - Reproduce Table 3 from Dai & Harrison (1991)
%
% This tests the iterative procedure for computing throughput gamma
% for lambda = 0.9, showing convergence of the iteration.
%
% Table 3 shows:
% - Trial value of gamma
% - Computed q1, q2
% - Computed delta2
% - New gamma = 1 - delta2

clear; clc;

fprintf('=================================================================\n');
fprintf('Reproducing Table 3 from Dai & Harrison (1991)\n');
fprintf('Iterative Calculation of gamma for lambda = 0.9\n');
fprintf('=================================================================\n\n');

% Parameters
a = 25;
b = 25;
lambda = 0.9;
n = 7;

% Reflection matrix
R = [1,  0, -1,  1;
    -1,  1,  0, -1];

% Reference values from Table 3
% Format: [trial_gamma, q1, q2, delta2, computed_gamma]
Table3_ref = [
    1.0,    5.3243, 6.7470, 0.10294, 0.898706;
    0.898706, 4.8450, 6.3146, 0.100453, 0.899547;
    0.899547, 4.8490, 6.3184, 0.100459, 0.899541;
];

fprintf('%-12s  %-12s %-12s %-12s %-12s\n', ...
    'Trial gamma', 'q1', 'q2', 'delta2', 'New gamma');
fprintf('-------------------------------------------------------------\n');

% Start iteration
gamma = 1.0;
num_iter = 3;

for iter = 1:num_iter
    % Set up RBM
    Gamma = gamma * eye(2);
    mu = [lambda - 1; 0];

    % Solve
    [q1, q2, d1, d2, d3, d4] = srbm_2d_solver(a, b, n, Gamma, mu, R);

    % Compute new gamma
    gamma_new = 1 - d2;

    fprintf('%-12.6f  %-12.4f %-12.4f %-12.6f %-12.6f\n', ...
        gamma, q1, q2, d2, gamma_new);

    gamma = gamma_new;
end

fprintf('\nReference values from paper:\n');
fprintf('%-12s  %-12s %-12s %-12s %-12s\n', ...
    'Trial gamma', 'q1', 'q2', 'delta2', 'New gamma');
fprintf('-------------------------------------------------------------\n');
for i = 1:size(Table3_ref, 1)
    fprintf('%-12.6f  %-12.4f %-12.4f %-12.6f %-12.6f\n', ...
        Table3_ref(i,1), Table3_ref(i,2), Table3_ref(i,3), ...
        Table3_ref(i,4), Table3_ref(i,5));
end

fprintf('\n=================================================================\n');
fprintf('Notes:\n');
fprintf('- The iteration converges quickly (3 iterations)\n');
fprintf('- Final gamma ≈ 0.8995 (throughput rate)\n');
fprintf('- Final q1 ≈ 4.85, q2 ≈ 6.32 (average queue lengths)\n');
fprintf('=================================================================\n');
