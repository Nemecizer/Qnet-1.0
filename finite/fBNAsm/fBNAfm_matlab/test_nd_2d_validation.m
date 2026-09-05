% test_nd_2d_validation.m - Validate n-dimensional solver against 2D results
%
% This tests the n-dimensional SRBM solver on the 2D case and compares
% with the known results from Table 2 of Dai & Harrison (1991).

clear; clc;

fprintf('=================================================================\n');
fprintf('Validating N-Dimensional Solver Against 2D Results\n');
fprintf('=================================================================\n\n');

%% Test 1: Compare with Table 2 entry (a=1.0)
fprintf('Test 1: Unit square with zero drift (Table 2, a=1.0)\n');
fprintf('----------------------------------------------------\n');

% Parameters matching Table 2
a_vec = [1; 1];  % 2D unit square
n_approx = 6;
Gamma = 2 * eye(2);  % Gamma = 2I for zero-drift case (Section 5)
mu = [0; 0];

% Reflection matrix for tandem queue (same as 2D case)
% Faces: F1 (x1=0), F2 (x1=a), F3 (x2=0), F4 (x2=b)
% But in n-D convention: F_{2k-1} = x_k=0, F_{2k} = x_k=a_k
% So: F1=x1=0, F2=x1=a, F3=x2=0, F4=x2=b
% 2D paper convention: v1 on x1=0, v2 on x2=0, v3 on x1=a, v4 on x2=b
% Need to reorder for n-D: [v_x1=0, v_x1=a, v_x2=0, v_x2=b]
v1 = [1; -1];   % x1=0
v2 = [0; 1];    % x2=0
v3 = [-1; 0];   % x1=a
v4 = [1; -1];   % x2=b
R = [v1, v3, v2, v4];  % Reorder: [x1=0, x1=a, x2=0, x2=b]

% Run n-dimensional solver
fprintf('Running n-dimensional solver...\n');
[q, delta, p_info] = srbm_nd_solver(a_vec, n_approx, Gamma, mu, R);

fprintf('\nResults from n-D solver:\n');
fprintf('  q1 = %.6f, q2 = %.6f\n', q(1), q(2));
fprintf('  delta1 (x1=0) = %.6f\n', delta(1));
fprintf('  delta2 (x1=a) = %.6f\n', delta(2));
fprintf('  delta3 (x2=0) = %.6f\n', delta(3));
fprintf('  delta4 (x2=b) = %.6f\n', delta(4));

fprintf('\nReference from Table 2 (SCPACK, a=1.0):\n');
fprintf('  q1 = 0.551506, q2 = 0.448494\n');
fprintf('  delta1 (x1=0) = 0.805295\n');
fprintf('  delta3 (x1=a) = 1.610589\n');
fprintf('  delta2 (x2=0) = 1.610589\n');
fprintf('  delta4 (x2=b) = 0.805295\n');

%% Test 2: Compare with original 2D solver
fprintf('\n\nTest 2: Direct comparison with 2D solver\n');
fprintf('-----------------------------------------\n');

% Run original 2D solver
R_2d = [1, 0, -1, 1; -1, 1, 0, -1];
[q1_2d, q2_2d, d1_2d, d2_2d, d3_2d, d4_2d] = srbm_2d_solver(1, 1, 6, Gamma, mu, R_2d);

fprintf('2D solver results:\n');
fprintf('  q1 = %.6f, q2 = %.6f\n', q1_2d, q2_2d);
fprintf('  d1 = %.6f, d2 = %.6f, d3 = %.6f, d4 = %.6f\n', d1_2d, d2_2d, d3_2d, d4_2d);

fprintf('\nN-D solver results (reordered to match 2D):\n');
fprintf('  q1 = %.6f, q2 = %.6f\n', q(1), q(2));
% Note: n-D uses [x1=0, x1=a, x2=0, x2=b], 2D uses [x1=0, x2=0, x1=a, x2=b]
fprintf('  d1 = %.6f, d2 = %.6f, d3 = %.6f, d4 = %.6f\n', delta(1), delta(3), delta(2), delta(4));

fprintf('\nDifferences:\n');
fprintf('  q1 diff: %.6f\n', abs(q(1) - q1_2d));
fprintf('  q2 diff: %.6f\n', abs(q(2) - q2_2d));

%% Test 3: Symmetric case
fprintf('\n\nTest 3: Symmetric case (normal reflection)\n');
fprintf('-------------------------------------------\n');

a_vec = [1; 1];
Gamma = eye(2);
mu = [0; 0];
R_sym = [1, -1, 0, 0;    % v1=(1,0), v2=(-1,0), v3=(0,1), v4=(0,-1)
         0, 0, 1, -1];

[q_sym, delta_sym, ~] = srbm_nd_solver(a_vec, 6, Gamma, mu, R_sym);

fprintf('For symmetric problem, expect q1 = q2 and symmetry in deltas\n');
fprintf('  q1 = %.6f, q2 = %.6f\n', q_sym(1), q_sym(2));
fprintf('  delta1 = %.6f, delta2 = %.6f\n', delta_sym(1), delta_sym(2));
fprintf('  delta3 = %.6f, delta4 = %.6f\n', delta_sym(3), delta_sym(4));

if abs(q_sym(1) - q_sym(2)) < 0.001
    fprintf('PASSED: Symmetry preserved\n');
else
    fprintf('WARNING: Symmetry not well preserved\n');
end

fprintf('\n=================================================================\n');
fprintf('2D Validation Complete\n');
fprintf('=================================================================\n');
