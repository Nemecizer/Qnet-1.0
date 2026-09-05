% test_nd_tandem_queue.m - Test n-dimensional tandem queue model
%
% This tests the SRBM solver on generalized tandem queue models.

clear; clc;

fprintf('=================================================================\n');
fprintf('Testing N-Dimensional Tandem Queue Model\n');
fprintf('=================================================================\n\n');

%% Test 1: Verify 2D tandem queue matches original results
fprintf('Test 1: 2D Tandem Queue (verify against Table 2)\n');
fprintf('-------------------------------------------------\n');

n_dim = 2;
a_vec = [1; 1];
n_approx = 6;
Gamma = 2 * eye(2);  % Gamma = 2I for zero-drift case
mu = [0; 0];
R = create_reflection_matrix(2, 'tandem');

fprintf('Reflection matrix R:\n');
disp(R);

[q, delta, ~] = srbm_nd_solver(a_vec, n_approx, Gamma, mu, R);

fprintf('N-D Solver Results:\n');
fprintf('  q1 = %.6f, q2 = %.6f\n', q(1), q(2));
fprintf('  delta(x1=0) = %.6f, delta(x1=1) = %.6f\n', delta(1), delta(2));
fprintf('  delta(x2=0) = %.6f, delta(x2=1) = %.6f\n', delta(3), delta(4));

fprintf('\nReference (Table 2, a=1.0):\n');
fprintf('  q1 = 0.551506, q2 = 0.448494\n');
fprintf('  delta1=0.805295, delta2=1.610589, delta3=1.610589, delta4=0.805295\n');

%% Test 2: 3-station tandem queue
fprintf('\n\nTest 2: 3-Station Tandem Queue (3D)\n');
fprintf('------------------------------------\n');

n_dim = 3;
a_vec = [5; 5; 5];  % Buffer size 4 + 1 in service at each station
n_approx = 3;
Gamma = eye(3);  % Identity covariance
mu = [-0.1; 0; 0];  % System slightly below critical load

R = create_reflection_matrix(3, 'tandem');
fprintf('Tandem queue reflection matrix R:\n');
disp(R);

[q, delta, ~] = srbm_nd_solver(a_vec, n_approx, Gamma, mu, R);

fprintf('Results:\n');
fprintf('  Expected queue lengths:\n');
for k = 1:n_dim
    fprintf('    E[Q%d] = %.4f\n', k, q(k));
end

fprintf('\n  Boundary measures (blocking/starvation rates):\n');
for face = 1:(2*n_dim)
    k = ceil(face/2);
    if mod(face, 2) == 1
        fprintf('    Queue %d empty rate: %.6f\n', k, delta(face));
    else
        fprintf('    Queue %d full rate:  %.6f\n', k, delta(face));
    end
end

%% Test 3: 4-station tandem queue at different loads
fprintf('\n\nTest 3: 4-Station Tandem Queue at Various Loads\n');
fprintf('------------------------------------------------\n');

n_dim = 4;
a_vec = [10; 10; 10; 10];
n_approx = 2;  % Lower order for 4D
R = create_reflection_matrix(4, 'tandem');

mu_values = [-0.2; -0.1; 0.0; 0.1];  % Different load levels

fprintf('%-8s', 'mu1');
for k = 1:n_dim
    fprintf('  E[Q%d]   ', k);
end
fprintf('\n');
fprintf(repmat('-', 1, 50));
fprintf('\n');

for mu1 = mu_values'
    mu = [mu1; 0; 0; 0];  % Only vary first component
    Gamma = eye(4);

    [q, ~, ~] = srbm_nd_solver(a_vec, n_approx, Gamma, mu, R);

    fprintf('%-8.2f', mu1);
    for k = 1:n_dim
        fprintf('  %7.3f', q(k));
    end
    fprintf('\n');
end

fprintf('\nNote: Negative mu1 means arrivals < service rate (light load)\n');
fprintf('      Positive mu1 means arrivals > service rate (heavy load)\n');

%% Test 4: Effect of buffer size in 3D tandem queue
fprintf('\n\nTest 4: Effect of Buffer Size in 3-Station Tandem Queue\n');
fprintf('-------------------------------------------------------\n');

n_dim = 3;
n_approx = 3;
mu = [0; 0; 0];  % Critical load
Gamma = eye(3);
R = create_reflection_matrix(3, 'tandem');

buffer_sizes = [2, 5, 10, 20];

fprintf('%-10s', 'Buffer');
for k = 1:n_dim
    fprintf('  E[Q%d]   ', k);
end
fprintf('  Sum(delta)\n');
fprintf(repmat('-', 1, 60));
fprintf('\n');

for buf = buffer_sizes
    a_vec = buf * ones(n_dim, 1);
    [q, delta, ~] = srbm_nd_solver(a_vec, n_approx, Gamma, mu, R);

    fprintf('%-10d', buf);
    for k = 1:n_dim
        fprintf('  %7.3f', q(k));
    end
    fprintf('  %7.3f\n', sum(delta));
end

fprintf('\n=================================================================\n');
fprintf('N-Dimensional Tandem Queue Tests Complete\n');
fprintf('=================================================================\n');
