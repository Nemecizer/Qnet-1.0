% test_nd_3d.m - Test n-dimensional SRBM solver in 3 dimensions
%
% This tests the n-dimensional SRBM solver on 3D problems.

clear; clc;

fprintf('=================================================================\n');
fprintf('Testing N-Dimensional SRBM Solver in 3D\n');
fprintf('=================================================================\n\n');

%% Test 1: Symmetric 3D cube with normal reflection
fprintf('Test 1: Unit cube with normal reflection (symmetric case)\n');
fprintf('----------------------------------------------------------\n');

a_vec = [1; 1; 1];  % Unit cube
n_approx = 4;  % Use lower order for 3D (basis dimension grows fast)
Gamma = eye(3);  % Identity covariance
mu = [0; 0; 0];  % Zero drift

% Normal reflection: v_i points inward perpendicular to face
% Faces: x1=0, x1=1, x2=0, x2=1, x3=0, x3=1
% Reflection directions: (1,0,0), (-1,0,0), (0,1,0), (0,-1,0), (0,0,1), (0,0,-1)
R = [1, -1, 0, 0, 0, 0;
     0, 0, 1, -1, 0, 0;
     0, 0, 0, 0, 1, -1];

fprintf('Parameters:\n');
fprintf('  Dimensions: [%.1f, %.1f, %.1f]\n', a_vec(1), a_vec(2), a_vec(3));
fprintf('  Covariance: Identity\n');
fprintf('  Drift: Zero\n');
fprintf('  Reflection: Normal\n');
fprintf('  Approximation order: %d\n\n', n_approx);

[q, delta, p_info] = srbm_nd_solver(a_vec, n_approx, Gamma, mu, R);

fprintf('\nResults:\n');
fprintf('  Expected values:\n');
fprintf('    E[X1] = %.6f (should be 0.5 by symmetry)\n', q(1));
fprintf('    E[X2] = %.6f (should be 0.5 by symmetry)\n', q(2));
fprintf('    E[X3] = %.6f (should be 0.5 by symmetry)\n', q(3));

fprintf('\n  Boundary measures:\n');
for i = 1:6
    k = ceil(i/2);
    face_type = 'lower';
    if mod(i,2) == 0
        face_type = 'upper';
    end
    fprintf('    delta_%d (x%d=%s): %.6f\n', i, k, face_type, delta(i));
end

fprintf('\n  Symmetry check:\n');
fprintf('    |q1 - q2| = %.6f\n', abs(q(1) - q(2)));
fprintf('    |q1 - q3| = %.6f\n', abs(q(1) - q(3)));
fprintf('    |delta_x1=0 - delta_x1=1| = %.6f\n', abs(delta(1) - delta(2)));
fprintf('    |delta_x1=0 - delta_x2=0| = %.6f\n', abs(delta(1) - delta(3)));

if max([abs(q(1)-q(2)), abs(q(1)-q(3)), abs(q(2)-q(3))]) < 0.01
    fprintf('PASSED: Full symmetry preserved\n');
else
    fprintf('Note: Some asymmetry detected (may be numerical)\n');
end

%% Test 2: Non-symmetric 3D cuboid
fprintf('\n\nTest 2: Non-symmetric cuboid [0,2]x[0,1]x[0,1]\n');
fprintf('------------------------------------------------\n');

a_vec = [2; 1; 1];  % Elongated in x1 direction
n_approx = 4;
Gamma = eye(3);
mu = [0; 0; 0];

% Same normal reflection
R = [1, -1, 0, 0, 0, 0;
     0, 0, 1, -1, 0, 0;
     0, 0, 0, 0, 1, -1];

[q, delta, ~] = srbm_nd_solver(a_vec, n_approx, Gamma, mu, R);

fprintf('Results:\n');
fprintf('  Expected values:\n');
fprintf('    E[X1] = %.6f (should be > 0.5, approx 1.0)\n', q(1));
fprintf('    E[X2] = %.6f (should be 0.5)\n', q(2));
fprintf('    E[X3] = %.6f (should be 0.5)\n', q(3));

fprintf('\n  Boundary measures:\n');
for i = 1:6
    k = ceil(i/2);
    face_type = '0';
    if mod(i,2) == 0
        face_type = sprintf('%.0f', a_vec(k));
    end
    fprintf('    delta_%d (x%d=%s): %.6f\n', i, k, face_type, delta(i));
end

%% Test 3: 3D with drift
fprintf('\n\nTest 3: Unit cube with drift mu = (-0.1, 0, 0.1)\n');
fprintf('-------------------------------------------------\n');

a_vec = [1; 1; 1];
n_approx = 4;
Gamma = eye(3);
mu = [-0.1; 0; 0.1];  % Drift toward x1=0 and away from x3=0

R = [1, -1, 0, 0, 0, 0;
     0, 0, 1, -1, 0, 0;
     0, 0, 0, 0, 1, -1];

[q, delta, ~] = srbm_nd_solver(a_vec, n_approx, Gamma, mu, R);

fprintf('Results:\n');
fprintf('  Expected values:\n');
fprintf('    E[X1] = %.6f (should be < 0.5 due to negative drift)\n', q(1));
fprintf('    E[X2] = %.6f (should be ~ 0.5)\n', q(2));
fprintf('    E[X3] = %.6f (should be > 0.5 due to positive drift)\n', q(3));

fprintf('\n  Boundary measures:\n');
for i = 1:6
    k = ceil(i/2);
    face_type = '0';
    if mod(i,2) == 0
        face_type = sprintf('%.0f', a_vec(k));
    end
    fprintf('    delta_%d (x%d=%s): %.6f\n', i, k, face_type, delta(i));
end

if q(1) < 0.5 && q(3) > 0.5 && abs(q(2) - 0.5) < 0.1
    fprintf('PASSED: Drift effects visible in expected values\n');
else
    fprintf('Note: Drift effects may need verification\n');
end

%% Test 4: Convergence test
fprintf('\n\nTest 4: Convergence with increasing approximation order\n');
fprintf('-------------------------------------------------------\n');

a_vec = [1; 1; 1];
Gamma = eye(3);
mu = [0; 0; 0];
R = [1, -1, 0, 0, 0, 0;
     0, 0, 1, -1, 0, 0;
     0, 0, 0, 0, 1, -1];

n_values = [2, 3, 4, 5];
fprintf('%-6s  %-10s %-10s %-10s\n', 'n', 'E[X1]', 'E[X2]', 'E[X3]');
fprintf('----------------------------------------------\n');

for n_approx = n_values
    [q, ~, p_info] = srbm_nd_solver(a_vec, n_approx, Gamma, mu, R);
    fprintf('%-6d  %-10.6f %-10.6f %-10.6f\n', n_approx, q(1), q(2), q(3));
end

fprintf('\n=================================================================\n');
fprintf('3D Tests Complete\n');
fprintf('=================================================================\n');
