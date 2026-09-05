function [q1, q2, delta1, delta2, delta3, delta4, p_interior, p_boundary] = srbm_2d_solver(a, b, n, Gamma, mu, R)
% SRBM_2D_SOLVER Compute stationary distribution of SRBM in rectangle [0,a]x[0,b]
%
% This implements the algorithm from Dai & Harrison (1991)
% "Steady-State Analysis of RBM in a Rectangle"
%
% Inputs:
%   a     - rectangle width (x1 in [0,a])
%   b     - rectangle height (x2 in [0,b])
%   n     - polynomial approximation order (typically 6)
%   Gamma - 2x2 covariance matrix
%   mu    - 2x1 drift vector
%   R     - 2x4 reflection matrix [v1 v2 v3 v4] where vi are reflection directions
%
% Outputs:
%   q1, q2           - expected values E[x1], E[x2] under stationary distribution
%   delta1,...,delta4 - boundary measures (integral of density on each face)
%   p_interior       - coefficients for interior density approximation
%   p_boundary       - coefficients for boundary densities
%
% Reference: J.G. Dai and J.M. Harrison, Ann. Appl. Prob. 1(1), 1991, pp. 16-35

    % Extract reflection vectors (columns of R)
    v1 = R(:,1); v2 = R(:,2); v3 = R(:,3); v4 = R(:,4);

    % Build the basis functions and their A-transforms
    % f_{k,i} = x1^i * x2^{k-i} for k=1,...,n and i=0,1,...,k
    % Total dimension: (n+1)(n+2)/2 - 1

    dim = (n+1)*(n+2)/2 - 1;

    % Generate list of (k,i) pairs
    basis_indices = [];
    for k = 1:n
        for i = 0:k
            basis_indices = [basis_indices; k, i];
        end
    end

    % Compute all A*f_{k,i} representations
    % Each Af is represented by:
    %   - interior polynomial coefficients (for the generator part)
    %   - boundary polynomial coefficients for each of the 4 faces

    Af_list = cell(dim, 1);
    for idx = 1:dim
        k = basis_indices(idx, 1);
        i = basis_indices(idx, 2);
        Af_list{idx} = compute_Af(k, i, a, b, Gamma, mu, v1, v2, v3, v4);
    end

    % Also compute phi_0 = 1 in interior, 0 on boundary
    phi0 = create_phi0(a, b);

    % Gram-Schmidt orthogonalization
    % We want to find the projection of phi_0 onto H_n = span{Af_{k,i}}

    [orthonormal_basis, coeffs_in_original] = gram_schmidt(Af_list, a, b);

    % Compute projection coefficients: a_i = (phi_0, phi_i)
    proj_coeffs = zeros(dim, 1);
    for idx = 1:dim
        proj_coeffs(idx) = inner_product(phi0, orthonormal_basis{idx}, a, b);
    end

    % w_n = phi_0 - sum_i a_i * phi_i
    % This gives the approximate solution (unnormalized)

    % Compute normalization constant alpha = integral of w_n over S
    % Since phi_0 = 1 in interior and 0 on boundary,
    % alpha = a*b - sum_i a_i * (integral of phi_i)

    alpha = compute_alpha(phi0, orthonormal_basis, proj_coeffs, a, b);

    % The normalized stationary density is p^n = (1/alpha) * w_n

    % Compute expected values q1 = E[x1], q2 = E[x2]
    % q1 = integral of x1 * p^n(x) dx over interior
    % q2 = integral of x2 * p^n(x) dx over interior

    [q1, q2] = compute_expected_values(phi0, orthonormal_basis, proj_coeffs, alpha, a, b);

    % Compute boundary measures delta_i = integral of p_i over F_i
    [delta1, delta2, delta3, delta4] = compute_boundary_measures(phi0, orthonormal_basis, proj_coeffs, alpha, a, b);

    % Store coefficients for visualization if needed
    p_interior = struct('alpha', alpha, 'proj_coeffs', proj_coeffs);
    p_boundary = struct('delta', [delta1, delta2, delta3, delta4]);
end

function Af = compute_Af(k, i, a, b, Gamma, mu, v1, v2, v3, v4)
% Compute A*f where f(x1,x2) = x1^i * x2^{k-i}
% Returns a struct with interior and boundary polynomial representations

    alpha_exp = i;       % exponent of x1
    beta_exp = k - i;    % exponent of x2

    % Interior: Af = (1/2)*sum_{ij} Gamma_ij * d^2f/dx_i dx_j + sum_i mu_i * df/dx_i
    % For f = x1^alpha * x2^beta:
    % df/dx1 = alpha * x1^{alpha-1} * x2^beta
    % df/dx2 = beta * x1^alpha * x2^{beta-1}
    % d^2f/dx1^2 = alpha*(alpha-1) * x1^{alpha-2} * x2^beta
    % d^2f/dx2^2 = beta*(beta-1) * x1^alpha * x2^{beta-2}
    % d^2f/dx1dx2 = alpha*beta * x1^{alpha-1} * x2^{beta-1}

    % Store interior polynomial as sparse representation: list of (coeff, exp1, exp2)
    interior_terms = [];

    % Second derivatives
    if alpha_exp >= 2
        coeff = 0.5 * Gamma(1,1) * alpha_exp * (alpha_exp - 1);
        interior_terms = [interior_terms; coeff, alpha_exp-2, beta_exp];
    end
    if beta_exp >= 2
        coeff = 0.5 * Gamma(2,2) * beta_exp * (beta_exp - 1);
        interior_terms = [interior_terms; coeff, alpha_exp, beta_exp-2];
    end
    if alpha_exp >= 1 && beta_exp >= 1
        coeff = Gamma(1,2) * alpha_exp * beta_exp;  % Gamma(1,2) = Gamma(2,1)
        interior_terms = [interior_terms; coeff, alpha_exp-1, beta_exp-1];
    end

    % First derivatives (drift terms)
    if alpha_exp >= 1
        coeff = mu(1) * alpha_exp;
        interior_terms = [interior_terms; coeff, alpha_exp-1, beta_exp];
    end
    if beta_exp >= 1
        coeff = mu(2) * beta_exp;
        interior_terms = [interior_terms; coeff, alpha_exp, beta_exp-1];
    end

    % Boundary operators: D_i f = v_i . grad(f)

    % F1: x1 = 0, parameterized by x2 in [0,b]
    % D1 f = v1(1)*df/dx1 + v1(2)*df/dx2
    % At x1=0: df/dx1 = alpha*0^{alpha-1}*x2^beta (=0 unless alpha=1)
    %          df/dx2 = beta*0^alpha*x2^{beta-1} (=0 unless alpha=0)
    boundary1_terms = [];
    if alpha_exp == 1
        coeff = v1(1) * 1;  % alpha * x1^{alpha-1} = 1 when alpha=1, x1=0
        boundary1_terms = [boundary1_terms; coeff, beta_exp];  % x2^beta
    end
    if alpha_exp == 0 && beta_exp >= 1
        coeff = v1(2) * beta_exp;
        boundary1_terms = [boundary1_terms; coeff, beta_exp-1];
    end

    % F2: x2 = 0, parameterized by x1 in [0,a]
    % D2 f = v2(1)*df/dx1 + v2(2)*df/dx2
    boundary2_terms = [];
    if beta_exp == 1
        coeff = v2(2) * 1;
        boundary2_terms = [boundary2_terms; coeff, alpha_exp];
    end
    if beta_exp == 0 && alpha_exp >= 1
        coeff = v2(1) * alpha_exp;
        boundary2_terms = [boundary2_terms; coeff, alpha_exp-1];
    end

    % F3: x1 = a, parameterized by x2 in [0,b]
    % D3 f = v3(1)*df/dx1 + v3(2)*df/dx2
    % At x1=a: df/dx1 = alpha*a^{alpha-1}*x2^beta
    %          df/dx2 = beta*a^alpha*x2^{beta-1}
    boundary3_terms = [];
    if alpha_exp >= 1
        coeff = v3(1) * alpha_exp * a^(alpha_exp-1);
        boundary3_terms = [boundary3_terms; coeff, beta_exp];
    end
    if beta_exp >= 1
        coeff = v3(2) * beta_exp * a^alpha_exp;
        boundary3_terms = [boundary3_terms; coeff, beta_exp-1];
    end

    % F4: x2 = b, parameterized by x1 in [0,a]
    % D4 f = v4(1)*df/dx1 + v4(2)*df/dx2
    boundary4_terms = [];
    if alpha_exp >= 1
        coeff = v4(1) * alpha_exp * b^beta_exp;
        boundary4_terms = [boundary4_terms; coeff, alpha_exp-1];
    end
    if beta_exp >= 1
        coeff = v4(2) * beta_exp * b^(beta_exp-1);
        boundary4_terms = [boundary4_terms; coeff, alpha_exp];
    end

    Af = struct();
    Af.interior = interior_terms;      % Nx3: [coeff, exp1, exp2]
    Af.boundary1 = boundary1_terms;    % Mx2: [coeff, exp] for x2
    Af.boundary2 = boundary2_terms;    % Mx2: [coeff, exp] for x1
    Af.boundary3 = boundary3_terms;    % Mx2: [coeff, exp] for x2
    Af.boundary4 = boundary4_terms;    % Mx2: [coeff, exp] for x1
end

function phi0 = create_phi0(a, b)
% Create phi_0: 1 in interior, 0 on boundary
    phi0 = struct();
    phi0.interior = [1, 0, 0];  % constant 1
    phi0.boundary1 = [];
    phi0.boundary2 = [];
    phi0.boundary3 = [];
    phi0.boundary4 = [];
end

function ip = inner_product(f, g, a, b)
% Compute inner product (f, g) = integral over S of f*g d_eta
% where d_eta = dx in interior, d_sigma on boundary

    ip = 0;

    % Interior contribution: integral of f*g over [0,a] x [0,b]
    ip = ip + interior_integral(f.interior, g.interior, a, b);

    % Boundary contributions
    ip = ip + boundary_integral_y(f.boundary1, g.boundary1, b);  % F1: x1=0
    ip = ip + boundary_integral_x(f.boundary2, g.boundary2, a);  % F2: x2=0
    ip = ip + boundary_integral_y(f.boundary3, g.boundary3, b);  % F3: x1=a
    ip = ip + boundary_integral_x(f.boundary4, g.boundary4, a);  % F4: x2=b
end

function val = interior_integral(terms1, terms2, a, b)
% Compute integral of product of two polynomials over [0,a] x [0,b]
% terms format: [coeff, exp1, exp2] for each term

    val = 0;
    if isempty(terms1) || isempty(terms2)
        return;
    end

    for i = 1:size(terms1, 1)
        c1 = terms1(i, 1);
        e1_1 = terms1(i, 2);
        e1_2 = terms1(i, 3);
        for j = 1:size(terms2, 1)
            c2 = terms2(j, 1);
            e2_1 = terms2(j, 2);
            e2_2 = terms2(j, 3);

            % Integral of x1^(e1_1+e2_1) * x2^(e1_2+e2_2) over [0,a] x [0,b]
            exp1_total = e1_1 + e2_1;
            exp2_total = e1_2 + e2_2;

            int_x1 = a^(exp1_total + 1) / (exp1_total + 1);
            int_x2 = b^(exp2_total + 1) / (exp2_total + 1);

            val = val + c1 * c2 * int_x1 * int_x2;
        end
    end
end

function val = boundary_integral_x(terms1, terms2, a)
% Compute integral of product of two 1D polynomials over [0,a]
% terms format: [coeff, exp] for each term

    val = 0;
    if isempty(terms1) || isempty(terms2)
        return;
    end

    for i = 1:size(terms1, 1)
        c1 = terms1(i, 1);
        e1 = terms1(i, 2);
        for j = 1:size(terms2, 1)
            c2 = terms2(j, 1);
            e2 = terms2(j, 2);

            exp_total = e1 + e2;
            int_val = a^(exp_total + 1) / (exp_total + 1);

            val = val + c1 * c2 * int_val;
        end
    end
end

function val = boundary_integral_y(terms1, terms2, b)
% Compute integral of product of two 1D polynomials over [0,b]
    val = boundary_integral_x(terms1, terms2, b);
end

function [ortho_basis, coeffs] = gram_schmidt(Af_list, a, b)
% Gram-Schmidt orthogonalization of Af_list

    dim = length(Af_list);
    ortho_basis = cell(dim, 1);
    coeffs = eye(dim);  % Transformation matrix

    for i = 1:dim
        % Start with Af_i
        ortho_basis{i} = Af_list{i};

        % Subtract projections onto previous orthonormal vectors
        for j = 1:(i-1)
            ip = inner_product(Af_list{i}, ortho_basis{j}, a, b);
            ortho_basis{i} = subtract_scaled(ortho_basis{i}, ortho_basis{j}, ip);
        end

        % Normalize
        norm_sq = inner_product(ortho_basis{i}, ortho_basis{i}, a, b);
        if norm_sq > 1e-14
            ortho_basis{i} = scale_func(ortho_basis{i}, 1/sqrt(norm_sq));
        end
    end
end

function result = subtract_scaled(f, g, scalar)
% Compute f - scalar * g for polynomial representations
    result = struct();
    result.interior = subtract_terms_2d(f.interior, g.interior, scalar);
    result.boundary1 = subtract_terms_1d(f.boundary1, g.boundary1, scalar);
    result.boundary2 = subtract_terms_1d(f.boundary2, g.boundary2, scalar);
    result.boundary3 = subtract_terms_1d(f.boundary3, g.boundary3, scalar);
    result.boundary4 = subtract_terms_1d(f.boundary4, g.boundary4, scalar);
end

function result = subtract_terms_2d(terms1, terms2, scalar)
% Subtract scalar*terms2 from terms1 (2D polynomial terms)
    result = terms1;
    if isempty(terms2)
        return;
    end
    for i = 1:size(terms2, 1)
        result = [result; -scalar*terms2(i,1), terms2(i,2), terms2(i,3)];
    end
    result = consolidate_terms_2d(result);
end

function result = subtract_terms_1d(terms1, terms2, scalar)
% Subtract scalar*terms2 from terms1 (1D polynomial terms)
    result = terms1;
    if isempty(terms2)
        return;
    end
    for i = 1:size(terms2, 1)
        result = [result; -scalar*terms2(i,1), terms2(i,2)];
    end
    result = consolidate_terms_1d(result);
end

function result = consolidate_terms_2d(terms)
% Combine terms with same exponents
    if isempty(terms)
        result = [];
        return;
    end

    % Use a map to combine like terms
    exp_map = containers.Map('KeyType', 'char', 'ValueType', 'double');
    for i = 1:size(terms, 1)
        key = sprintf('%d_%d', terms(i,2), terms(i,3));
        if isKey(exp_map, key)
            exp_map(key) = exp_map(key) + terms(i,1);
        else
            exp_map(key) = terms(i,1);
        end
    end

    keys = exp_map.keys;
    result = zeros(length(keys), 3);
    for i = 1:length(keys)
        parts = sscanf(keys{i}, '%d_%d');
        result(i,:) = [exp_map(keys{i}), parts(1), parts(2)];
    end

    % Remove zero terms
    result = result(abs(result(:,1)) > 1e-15, :);
end

function result = consolidate_terms_1d(terms)
% Combine terms with same exponents (1D case)
    if isempty(terms)
        result = [];
        return;
    end

    max_exp = max(terms(:,2));
    coeffs = zeros(max_exp + 1, 1);
    for i = 1:size(terms, 1)
        exp_idx = terms(i,2) + 1;
        coeffs(exp_idx) = coeffs(exp_idx) + terms(i,1);
    end

    result = [];
    for i = 1:length(coeffs)
        if abs(coeffs(i)) > 1e-15
            result = [result; coeffs(i), i-1];
        end
    end
end

function result = scale_func(f, scalar)
% Scale all coefficients by scalar
    result = struct();
    result.interior = scale_terms(f.interior, scalar);
    result.boundary1 = scale_terms(f.boundary1, scalar);
    result.boundary2 = scale_terms(f.boundary2, scalar);
    result.boundary3 = scale_terms(f.boundary3, scalar);
    result.boundary4 = scale_terms(f.boundary4, scalar);
end

function result = scale_terms(terms, scalar)
    result = terms;
    if ~isempty(result)
        result(:,1) = result(:,1) * scalar;
    end
end

function alpha = compute_alpha(phi0, ortho_basis, proj_coeffs, a, b)
% Compute normalization constant alpha = integral of (phi_tilde_0 * phi_0) over S
% Since phi_0 = 1 in interior and 0 on boundary, this equals:
% alpha = integral of phi_tilde_0 over INTERIOR only
% phi_tilde_0 = phi_0 - projection = w_n (unnormalized solution)

    % Integral of phi_0 over interior = a * b (since phi_0 = 1 in interior)
    alpha = a * b;

    % Subtract contributions from projection (INTERIOR ONLY)
    for i = 1:length(proj_coeffs)
        % Integral of phi_i over interior only (not boundary!)
        int_phi_i = integral_over_interior(ortho_basis{i}, a, b);
        alpha = alpha - proj_coeffs(i) * int_phi_i;
    end
end

function val = integral_over_interior(f, a, b)
% Compute integral of f over interior [0,a] x [0,b] only
    val = 0;
    for i = 1:size(f.interior, 1)
        c = f.interior(i, 1);
        e1 = f.interior(i, 2);
        e2 = f.interior(i, 3);
        val = val + c * a^(e1+1)/(e1+1) * b^(e2+1)/(e2+1);
    end
end

function val = integral_over_S(f, a, b)
% Compute integral of f over S (interior + boundary)
    val = 0;

    % Interior
    for i = 1:size(f.interior, 1)
        c = f.interior(i, 1);
        e1 = f.interior(i, 2);
        e2 = f.interior(i, 3);
        val = val + c * a^(e1+1)/(e1+1) * b^(e2+1)/(e2+1);
    end

    % Boundaries
    for i = 1:size(f.boundary1, 1)
        c = f.boundary1(i, 1);
        e = f.boundary1(i, 2);
        val = val + c * b^(e+1)/(e+1);
    end
    for i = 1:size(f.boundary2, 1)
        c = f.boundary2(i, 1);
        e = f.boundary2(i, 2);
        val = val + c * a^(e+1)/(e+1);
    end
    for i = 1:size(f.boundary3, 1)
        c = f.boundary3(i, 1);
        e = f.boundary3(i, 2);
        val = val + c * b^(e+1)/(e+1);
    end
    for i = 1:size(f.boundary4, 1)
        c = f.boundary4(i, 1);
        e = f.boundary4(i, 2);
        val = val + c * a^(e+1)/(e+1);
    end
end

function [q1, q2] = compute_expected_values(phi0, ortho_basis, proj_coeffs, alpha, a, b)
% Compute q1 = E[x1] and q2 = E[x2] under the stationary distribution
% q_i = (1/alpha) * integral of x_i * w_n(x) dx (interior only)

    % w_n = phi_0 - sum_i a_i * phi_i
    % integral of x1 * phi_0 = integral of x1 over [0,a]x[0,b] = (a^2/2) * b
    int_x1_phi0 = (a^2/2) * b;
    int_x2_phi0 = a * (b^2/2);

    % Subtract projection contributions
    int_x1_proj = 0;
    int_x2_proj = 0;
    for i = 1:length(proj_coeffs)
        % Integral of x1 * phi_i over interior
        int_x1_proj = int_x1_proj + proj_coeffs(i) * integral_x1_times_f(ortho_basis{i}, a, b);
        int_x2_proj = int_x2_proj + proj_coeffs(i) * integral_x2_times_f(ortho_basis{i}, a, b);
    end

    q1 = (int_x1_phi0 - int_x1_proj) / alpha;
    q2 = (int_x2_phi0 - int_x2_proj) / alpha;
end

function val = integral_x1_times_f(f, a, b)
% Integral of x1 * f(x) over interior [0,a] x [0,b]
    val = 0;
    for i = 1:size(f.interior, 1)
        c = f.interior(i, 1);
        e1 = f.interior(i, 2);
        e2 = f.interior(i, 3);
        % Integral of x1^{e1+1} * x2^{e2}
        val = val + c * a^(e1+2)/(e1+2) * b^(e2+1)/(e2+1);
    end
end

function val = integral_x2_times_f(f, a, b)
% Integral of x2 * f(x) over interior [0,a] x [0,b]
    val = 0;
    for i = 1:size(f.interior, 1)
        c = f.interior(i, 1);
        e1 = f.interior(i, 2);
        e2 = f.interior(i, 3);
        % Integral of x1^{e1} * x2^{e2+1}
        val = val + c * a^(e1+1)/(e1+1) * b^(e2+2)/(e2+2);
    end
end

function [d1, d2, d3, d4] = compute_boundary_measures(phi0, ortho_basis, proj_coeffs, alpha, a, b)
% Compute delta_i = integral of p_i over F_i (boundary measures)
% These come from the boundary parts of w_n / alpha

    % w_n has boundary parts: 0 (from phi_0) - sum_i a_i * (boundary parts of phi_i)
    % So delta_k = -(1/alpha) * sum_i a_i * integral of phi_i over F_k

    d1 = 0; d2 = 0; d3 = 0; d4 = 0;
    for i = 1:length(proj_coeffs)
        % Integral over F1 (x1=0)
        for j = 1:size(ortho_basis{i}.boundary1, 1)
            c = ortho_basis{i}.boundary1(j, 1);
            e = ortho_basis{i}.boundary1(j, 2);
            d1 = d1 - proj_coeffs(i) * c * b^(e+1)/(e+1);
        end
        % Integral over F2 (x2=0)
        for j = 1:size(ortho_basis{i}.boundary2, 1)
            c = ortho_basis{i}.boundary2(j, 1);
            e = ortho_basis{i}.boundary2(j, 2);
            d2 = d2 - proj_coeffs(i) * c * a^(e+1)/(e+1);
        end
        % Integral over F3 (x1=a)
        for j = 1:size(ortho_basis{i}.boundary3, 1)
            c = ortho_basis{i}.boundary3(j, 1);
            e = ortho_basis{i}.boundary3(j, 2);
            d3 = d3 - proj_coeffs(i) * c * b^(e+1)/(e+1);
        end
        % Integral over F4 (x2=b)
        for j = 1:size(ortho_basis{i}.boundary4, 1)
            c = ortho_basis{i}.boundary4(j, 1);
            e = ortho_basis{i}.boundary4(j, 2);
            d4 = d4 - proj_coeffs(i) * c * a^(e+1)/(e+1);
        end
    end

    d1 = d1 / alpha;
    d2 = d2 / alpha;
    d3 = d3 / alpha;
    d4 = d4 / alpha;
end
