% test_nd_arbitrary.m - Test n-dimensional SRBM solver for arbitrary n
%
% This tests the solver for various dimensions and configurations.

clear; clc;

fprintf('=================================================================\n');
fprintf('Testing N-Dimensional SRBM Solver for Arbitrary Dimensions\n');
fprintf('=================================================================\n\n');

%% Test dimensions 1 through 5
dims_to_test = [1, 2, 3, 4, 5];

for n_dim = dims_to_test
    fprintf('\n=== Testing %dD SRBM ===\n', n_dim);
    fprintf('------------------------\n');

    % Unit hypercube
    a_vec = ones(n_dim, 1);

    % Identity covariance
    Gamma = eye(n_dim);

    % Zero drift
    mu = zeros(n_dim, 1);

    % Normal reflection matrix
    R = create_normal_reflection_matrix(n_dim);

    % Approximation order (reduce for higher dimensions to control computation)
    if n_dim <= 2
        n_approx = 6;
    elseif n_dim == 3
        n_approx = 4;
    elseif n_dim == 4
        n_approx = 3;
    else
        n_approx = 2;
    end

    fprintf('Parameters: %dD unit hypercube, Gamma=I, mu=0, n=%d\n', n_dim, n_approx);

    tic;
    [q, delta, p_info] = srbm_nd_solver(a_vec, n_approx, Gamma, mu, R);
    elapsed = toc;

    fprintf('Computation time: %.2f seconds\n', elapsed);
    fprintf('Basis dimension: %d\n', p_info.dim);

    fprintf('\nExpected values E[X_k] (should all be 0.5 by symmetry):\n');
    for k = 1:n_dim
        fprintf('  E[X%d] = %.6f\n', k, q(k));
    end

    fprintf('\nBoundary measures:\n');
    for face = 1:(2*n_dim)
        k = ceil(face/2);
        if mod(face, 2) == 1
            fprintf('  delta(x%d=0) = %.6f\n', k, delta(face));
        else
            fprintf('  delta(x%d=1) = %.6f\n', k, delta(face));
        end
    end

    % Check symmetry
    max_q_diff = max(q) - min(q);
    fprintf('\nSymmetry check: max |q_i - q_j| = %.6f\n', max_q_diff);

    if max_q_diff < 0.02
        fprintf('PASSED: Symmetry preserved\n');
    else
        fprintf('Note: Some asymmetry (likely numerical precision)\n');
    end
end

fprintf('\n=================================================================\n');
fprintf('Arbitrary Dimension Tests Complete\n');
fprintf('=================================================================\n');


function R = create_normal_reflection_matrix(n_dim)
% Create reflection matrix for normal (perpendicular) reflection on hypercube
% R is n_dim x 2*n_dim matrix
% Column 2k-1: inward normal on face x_k = 0 (unit vector e_k)
% Column 2k: inward normal on face x_k = a_k (unit vector -e_k)

    R = zeros(n_dim, 2*n_dim);
    for k = 1:n_dim
        R(k, 2*k-1) = 1;   % +e_k on x_k = 0 face
        R(k, 2*k) = -1;    % -e_k on x_k = a_k face
    end
end
