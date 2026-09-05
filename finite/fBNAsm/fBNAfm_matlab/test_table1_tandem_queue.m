% test_table1_tandem_queue.m - Reproduce Table 1 from Dai & Harrison (1991)
%
% This tests the iterative procedure for computing throughput and queue lengths
% for the tandem queue model described in Section 6 of the paper.
%
% The tandem queue has:
% - Poisson arrivals with rate lambda
% - Deterministic service at station 1 (tau1 = 1)
% - Exponential service at station 2 (mean tau2 = 1)
% - Buffer capacity b1 = b2 = 24 at each station
%
% The QNET method approximates this with an RBM on [0,25] x [0,25]

clear; clc;

fprintf('=================================================================\n');
fprintf('Reproducing Table 1 from Dai & Harrison (1991)\n');
fprintf('Tandem Queue Performance Analysis\n');
fprintf('=================================================================\n\n');

% Parameters from Section 6
% Rectangle size: 25 x 25 (buffer of 24 + 1 for customer in service)
a = 25;
b = 25;

% Reflection matrix for tandem queue (equation 38)
R = [1,  0, -1,  1;
    -1,  1,  0, -1];

% Approximation order
n = 7;  % Paper mentions n=7 for Table 1

% Arrival rates to test
lambda_values = [0.9, 1.0, 1.1, 1.2];

% Reference values from Table 1 (QNET estimates)
% Format: [gamma, q1, q2]
QNET_ref = [
    0.8995, 4.8490, 6.3184;   % lambda = 0.9
    0.9688, 13.75, 11.25;     % lambda = 1.0
    0.9801, 20.5239, 12.4445; % lambda = 1.1
    0.9807, 22.2688, 12.4676; % lambda = 1.2
];

% Simulation reference values from Table 1
SIM_ref = [
    0.8991, 5.1291, 6.2691;   % lambda = 0.9
    0.9690, 13.87, 11.07;     % lambda = 1.0
    0.9801, 20.4801, 12.3801; % lambda = 1.1
    0.9804, 22.4804, 12.4804; % lambda = 1.2
];

fprintf('Computing QNET estimates for tandem queue...\n\n');

fprintf('%-8s  %-10s %-10s %-10s\n', 'lambda', 'gamma', 'q1', 'q2');
fprintf('---------------------------------------------\n');

for i = 1:length(lambda_values)
    lambda = lambda_values(i);

    % Iterative procedure from Section 6
    % Start with trial gamma = 1.0
    gamma = 1.0;
    tol = 1e-6;
    max_iter = 20;

    for iter = 1:max_iter
        % Set up RBM parameters for current gamma estimate
        % Covariance matrix: Gamma = gamma * I (equation 40)
        Gamma = gamma * eye(2);

        % Drift vector: mu = (lambda - 1, 0)^T (equation 41)
        mu = [lambda - 1; 0];

        % Solve SRBM
        [q1, q2, d1, d2, d3, d4] = srbm_2d_solver(a, b, n, Gamma, mu, R);

        % Update gamma using equation (47): gamma = 1 - delta2
        gamma_new = 1 - d2;

        if abs(gamma_new - gamma) < tol
            gamma = gamma_new;
            break;
        end
        gamma = gamma_new;
    end

    % Scale q values for the actual queue
    % q1_actual = q1, q2_actual = q2 (they're already in the right scale)

    fprintf('lambda=%.1f: gamma=%8.4f  q1=%8.4f  q2=%8.4f\n', ...
        lambda, gamma, q1, q2);
    fprintf('  QNET ref: gamma=%8.4f  q1=%8.4f  q2=%8.4f\n', ...
        QNET_ref(i,1), QNET_ref(i,2), QNET_ref(i,3));
    fprintf('  SIM  ref: gamma=%8.4f  q1=%8.4f  q2=%8.4f\n', ...
        SIM_ref(i,1), SIM_ref(i,2), SIM_ref(i,3));
    fprintf('\n');
end

fprintf('=================================================================\n');
fprintf('Notes:\n');
fprintf('- gamma is the throughput rate\n');
fprintf('- q1, q2 are expected queue lengths at stations 1 and 2\n');
fprintf('- For lambda=1.0, the system is at critical load\n');
fprintf('- For lambda>1.0, the arrival rate exceeds service capacity\n');
fprintf('=================================================================\n');
