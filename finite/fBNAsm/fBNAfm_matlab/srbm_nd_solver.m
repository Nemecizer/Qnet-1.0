function [q, delta, p_info] = srbm_nd_solver(a_vec, n_approx, Gamma, mu, R)
% SRBM_ND_SOLVER Compute stationary distribution of SRBM in n-dimensional hypercube
%
% This implements the generalized algorithm from Dai & Harrison (1991)
% extended to arbitrary dimensions.
%
% Inputs:
%   a_vec    - n x 1 vector of hypercube dimensions (x_k in [0, a_k])
%   n_approx - polynomial approximation order (typically 4-7)
%   Gamma    - n x n covariance matrix
%   mu       - n x 1 drift vector
%   R        - n x 2n reflection matrix [v_1 v_2 ... v_{2n}]
%              where v_{2k-1} is reflection direction on face x_k=0
%              and v_{2k} is reflection direction on face x_k=a_k
%
% Outputs:
%   q        - n x 1 vector of expected values E[x_k] under stationary distribution
%   delta    - 2n x 1 vector of boundary measures on each face
%   p_info   - struct with additional information (alpha, proj_coeffs, etc.)
%
% Reference: J.G. Dai and J.M. Harrison, Ann. Appl. Prob. 1(1), 1991, pp. 16-35

    n_dim = length(a_vec);
    a_vec = a_vec(:);  % Ensure column vector
    mu = mu(:);

    % Validate inputs
    assert(size(Gamma, 1) == n_dim && size(Gamma, 2) == n_dim, ...
        'Gamma must be n x n');
    assert(length(mu) == n_dim, 'mu must be n x 1');
    assert(size(R, 1) == n_dim && size(R, 2) == 2*n_dim, ...
        'R must be n x 2n');

    % Generate all multi-indices for basis functions
    % f_alpha = x_1^{alpha_1} * x_2^{alpha_2} * ... * x_n^{alpha_n}
    % with 1 <= |alpha| <= n_approx
    multi_indices = generate_multi_indices(n_dim, n_approx);
    dim = size(multi_indices, 1);

    fprintf('SRBM solver: n=%d dimensions, order=%d, basis dimension=%d\n', ...
        n_dim, n_approx, dim);

    % Compute all A*f_alpha representations
    Af_list = cell(dim, 1);
    for idx = 1:dim
        alpha = multi_indices(idx, :);
        Af_list{idx} = compute_Af_nd(alpha, a_vec, Gamma, mu, R);
    end

    % Create phi_0 = 1 in interior, 0 on all boundaries
    phi0 = create_phi0_nd(n_dim);

    % Gram-Schmidt orthogonalization
    fprintf('Performing Gram-Schmidt orthogonalization...\n');
    orthonormal_basis = gram_schmidt_nd(Af_list, a_vec);

    % Compute projection coefficients: a_i = (phi_0, phi_i)
    proj_coeffs = zeros(dim, 1);
    for idx = 1:dim
        proj_coeffs(idx) = inner_product_nd(phi0, orthonormal_basis{idx}, a_vec);
    end

    % Compute normalization constant alpha (interior integral only)
    alpha = compute_alpha_nd(phi0, orthonormal_basis, proj_coeffs, a_vec);

    % Compute expected values q_k = E[x_k]
    q = compute_expected_values_nd(phi0, orthonormal_basis, proj_coeffs, alpha, a_vec);

    % Compute boundary measures delta_i = integral of p_i over F_i
    delta = compute_boundary_measures_nd(orthonormal_basis, proj_coeffs, alpha, a_vec);

    % Store additional info
    p_info = struct();
    p_info.alpha = alpha;
    p_info.proj_coeffs = proj_coeffs;
    p_info.multi_indices = multi_indices;
    p_info.dim = dim;

    fprintf('Solver complete. alpha = %.6f\n', alpha);
end

function indices = generate_multi_indices(n_dim, max_order)
% Generate all multi-indices alpha with 1 <= |alpha| <= max_order
% Returns matrix where each row is a multi-index [alpha_1, ..., alpha_n]

    indices = [];

    % Generate indices for each total degree k = 1, 2, ..., max_order
    for k = 1:max_order
        new_indices = generate_indices_of_degree(n_dim, k);
        indices = [indices; new_indices];
    end
end

function indices = generate_indices_of_degree(n_dim, k)
% Generate all multi-indices with exactly degree k in n dimensions
% Uses recursive approach: place k balls into n bins

    if n_dim == 1
        indices = k;
        return;
    end

    indices = [];
    for i = 0:k
        % First component is i, remaining components sum to k-i
        sub_indices = generate_indices_of_degree(n_dim - 1, k - i);
        n_sub = size(sub_indices, 1);
        new_block = [i * ones(n_sub, 1), sub_indices];
        indices = [indices; new_block];
    end
end

function Af = compute_Af_nd(alpha, a_vec, Gamma, mu, R)
% Compute A*f where f(x) = x^alpha = x_1^{alpha_1} * ... * x_n^{alpha_n}
% Returns struct with interior polynomial and 2n boundary polynomials

    n_dim = length(a_vec);

    % Interior: Af = (1/2)*sum_{ij} Gamma_ij * d^2f/dx_i dx_j + sum_i mu_i * df/dx_i
    interior_terms = compute_interior_generator(alpha, Gamma, mu);

    % Boundary operators: D_k f = v_k . grad(f) on each face
    boundary_terms = cell(2*n_dim, 1);
    for face = 1:(2*n_dim)
        boundary_terms{face} = compute_boundary_operator(alpha, a_vec, R, face);
    end

    Af = struct();
    Af.interior = interior_terms;
    Af.boundaries = boundary_terms;
    Af.n_dim = n_dim;
end

function terms = compute_interior_generator(alpha, Gamma, mu)
% Compute generator Lf in the interior for f = x^alpha
% L = (1/2) sum_{ij} Gamma_ij d^2/dx_i dx_j + sum_i mu_i d/dx_i

    n_dim = length(alpha);
    terms = [];

    % Second derivative terms: (1/2) Gamma_ij * d^2f/dx_i dx_j
    for i = 1:n_dim
        for j = 1:n_dim
            if Gamma(i,j) == 0
                continue;
            end

            if i == j
                % d^2f/dx_i^2 = alpha_i * (alpha_i - 1) * x^{alpha - 2*e_i}
                if alpha(i) >= 2
                    new_alpha = alpha;
                    new_alpha(i) = new_alpha(i) - 2;
                    coeff = 0.5 * Gamma(i,i) * alpha(i) * (alpha(i) - 1);
                    terms = [terms; coeff, new_alpha];
                end
            else
                % d^2f/dx_i dx_j = alpha_i * alpha_j * x^{alpha - e_i - e_j}
                if alpha(i) >= 1 && alpha(j) >= 1
                    new_alpha = alpha;
                    new_alpha(i) = new_alpha(i) - 1;
                    new_alpha(j) = new_alpha(j) - 1;
                    coeff = 0.5 * Gamma(i,j) * alpha(i) * alpha(j);
                    terms = [terms; coeff, new_alpha];
                end
            end
        end
    end

    % First derivative terms: mu_i * df/dx_i
    for i = 1:n_dim
        if mu(i) == 0 || alpha(i) < 1
            continue;
        end
        new_alpha = alpha;
        new_alpha(i) = new_alpha(i) - 1;
        coeff = mu(i) * alpha(i);
        terms = [terms; coeff, new_alpha];
    end

    % Consolidate terms with same exponents
    terms = consolidate_terms_nd(terms);
end

function terms = compute_boundary_operator(alpha, a_vec, R, face)
% Compute boundary operator D_face f = v_face . grad(f) on face F_face
% face = 2k-1 means x_k = 0, face = 2k means x_k = a_k

    n_dim = length(a_vec);
    k = ceil(face / 2);  % Which dimension is fixed
    is_lower = (mod(face, 2) == 1);  % x_k = 0 or x_k = a_k

    v = R(:, face);  % Reflection direction for this face

    % At the boundary, x_k is fixed at either 0 or a_k
    x_k_val = 0;
    if ~is_lower
        x_k_val = a_vec(k);
    end

    terms = [];

    % D_face f = sum_i v_i * df/dx_i evaluated at the boundary
    for i = 1:n_dim
        if v(i) == 0 || alpha(i) < 1
            continue;
        end

        % df/dx_i = alpha_i * x^{alpha - e_i}
        % Evaluate at x_k = x_k_val

        % The coefficient includes the factor from x_k^{alpha_k} evaluated at boundary
        new_alpha = alpha;
        new_alpha(i) = new_alpha(i) - 1;

        % Evaluate: coefficient from derivative * x_k^{new_alpha_k} at x_k = x_k_val
        if is_lower  % x_k = 0
            % x_k^{new_alpha_k} = 0^{new_alpha_k}
            % This is 0 unless new_alpha_k = 0 (i.e., the term doesn't depend on x_k)
            if new_alpha(k) ~= 0
                continue;  % Term vanishes at x_k = 0
            end
            coeff = v(i) * alpha(i);
        else  % x_k = a_k
            coeff = v(i) * alpha(i) * (x_k_val ^ new_alpha(k));
        end

        % Store the term: we remove the k-th exponent since x_k is fixed
        boundary_alpha = [new_alpha(1:k-1), new_alpha(k+1:end)];
        terms = [terms; coeff, boundary_alpha];
    end

    % Consolidate terms
    if ~isempty(terms)
        terms = consolidate_boundary_terms(terms);
    end
end

function terms = consolidate_terms_nd(terms)
% Combine terms with same exponents (n-dimensional interior)
    if isempty(terms)
        return;
    end

    n_dim = size(terms, 2) - 1;

    % Use a map to combine like terms
    exp_map = containers.Map('KeyType', 'char', 'ValueType', 'double');
    for i = 1:size(terms, 1)
        key = sprintf('%d_', terms(i, 2:end));
        if isKey(exp_map, key)
            exp_map(key) = exp_map(key) + terms(i, 1);
        else
            exp_map(key) = terms(i, 1);
        end
    end

    keys = exp_map.keys;
    result = zeros(length(keys), n_dim + 1);
    for i = 1:length(keys)
        parts = sscanf(keys{i}, '%d_');
        result(i, :) = [exp_map(keys{i}), parts'];
    end

    % Remove near-zero terms
    terms = result(abs(result(:,1)) > 1e-14, :);
end

function terms = consolidate_boundary_terms(terms)
% Combine terms with same exponents (boundary, n-1 dimensional)
    if isempty(terms)
        return;
    end

    n_dim_boundary = size(terms, 2) - 1;

    if n_dim_boundary == 0
        % 1D case: boundary is just a point, sum coefficients
        terms = [sum(terms(:,1))];
        if abs(terms) < 1e-14
            terms = [];
        end
        return;
    end

    exp_map = containers.Map('KeyType', 'char', 'ValueType', 'double');
    for i = 1:size(terms, 1)
        key = sprintf('%d_', terms(i, 2:end));
        if isKey(exp_map, key)
            exp_map(key) = exp_map(key) + terms(i, 1);
        else
            exp_map(key) = terms(i, 1);
        end
    end

    keys = exp_map.keys;
    result = zeros(length(keys), n_dim_boundary + 1);
    for i = 1:length(keys)
        parts = sscanf(keys{i}, '%d_');
        result(i, :) = [exp_map(keys{i}), parts'];
    end

    terms = result(abs(result(:,1)) > 1e-14, :);
end

function phi0 = create_phi0_nd(n_dim)
% Create phi_0: 1 in interior, 0 on all boundaries
    phi0 = struct();
    phi0.interior = [1, zeros(1, n_dim)];  % Constant 1
    phi0.boundaries = cell(2*n_dim, 1);
    for i = 1:(2*n_dim)
        phi0.boundaries{i} = [];  % Zero on all boundaries
    end
    phi0.n_dim = n_dim;
end

function ip = inner_product_nd(f, g, a_vec)
% Compute inner product (f, g) in L^2(S, eta)
% eta = dx in interior, d_sigma on boundary faces

    n_dim = length(a_vec);
    ip = 0;

    % Interior contribution
    ip = ip + interior_integral_nd(f.interior, g.interior, a_vec);

    % Boundary contributions
    for face = 1:(2*n_dim)
        k = ceil(face / 2);
        a_boundary = [a_vec(1:k-1); a_vec(k+1:end)];
        ip = ip + boundary_integral_nd(f.boundaries{face}, g.boundaries{face}, a_boundary);
    end
end

function val = interior_integral_nd(terms1, terms2, a_vec)
% Compute integral of product of two polynomials over hypercube [0,a_1]x...x[0,a_n]

    val = 0;
    if isempty(terms1) || isempty(terms2)
        return;
    end

    n_dim = length(a_vec);

    for i = 1:size(terms1, 1)
        c1 = terms1(i, 1);
        exp1 = terms1(i, 2:end);

        for j = 1:size(terms2, 1)
            c2 = terms2(j, 1);
            exp2 = terms2(j, 2:end);

            % Integral of product x^{exp1 + exp2} over hypercube
            exp_total = exp1 + exp2;
            int_val = 1;
            for d = 1:n_dim
                int_val = int_val * a_vec(d)^(exp_total(d) + 1) / (exp_total(d) + 1);
            end

            val = val + c1 * c2 * int_val;
        end
    end
end

function val = boundary_integral_nd(terms1, terms2, a_boundary)
% Compute integral of product of two polynomials over (n-1)-dimensional boundary

    val = 0;
    if isempty(terms1) || isempty(terms2)
        return;
    end

    n_dim_boundary = length(a_boundary);

    if n_dim_boundary == 0
        % 0D boundary (corner point in 1D problem)
        val = terms1(1) * terms2(1);
        return;
    end

    for i = 1:size(terms1, 1)
        c1 = terms1(i, 1);
        exp1 = terms1(i, 2:end);

        for j = 1:size(terms2, 1)
            c2 = terms2(j, 1);
            exp2 = terms2(j, 2:end);

            exp_total = exp1 + exp2;
            int_val = 1;
            for d = 1:n_dim_boundary
                int_val = int_val * a_boundary(d)^(exp_total(d) + 1) / (exp_total(d) + 1);
            end

            val = val + c1 * c2 * int_val;
        end
    end
end

function ortho_basis = gram_schmidt_nd(Af_list, a_vec)
% Gram-Schmidt orthogonalization of Af_list

    dim = length(Af_list);
    ortho_basis = cell(dim, 1);

    for i = 1:dim
        if mod(i, 50) == 0
            fprintf('  Gram-Schmidt: processing basis %d/%d\n', i, dim);
        end

        % Start with Af_i
        ortho_basis{i} = Af_list{i};

        % Subtract projections onto previous orthonormal vectors
        for j = 1:(i-1)
            ip = inner_product_nd(Af_list{i}, ortho_basis{j}, a_vec);
            ortho_basis{i} = subtract_scaled_nd(ortho_basis{i}, ortho_basis{j}, ip);
        end

        % Normalize
        norm_sq = inner_product_nd(ortho_basis{i}, ortho_basis{i}, a_vec);
        if norm_sq > 1e-14
            ortho_basis{i} = scale_func_nd(ortho_basis{i}, 1/sqrt(norm_sq));
        end
    end
end

function result = subtract_scaled_nd(f, g, scalar)
% Compute f - scalar * g for n-dimensional polynomial representations

    result = struct();
    result.n_dim = f.n_dim;
    result.interior = subtract_terms(f.interior, g.interior, scalar, f.n_dim);

    n_faces = 2 * f.n_dim;
    result.boundaries = cell(n_faces, 1);
    for face = 1:n_faces
        k = ceil(face / 2);
        n_dim_boundary = f.n_dim - 1;
        result.boundaries{face} = subtract_terms(f.boundaries{face}, g.boundaries{face}, scalar, n_dim_boundary);
    end
end

function result = subtract_terms(terms1, terms2, scalar, n_dim)
% Subtract scalar*terms2 from terms1

    if isempty(terms2)
        result = terms1;
        return;
    end

    if isempty(terms1)
        result = terms2;
        result(:, 1) = -scalar * result(:, 1);
        return;
    end

    % Handle case of 0D (scalar) terms
    if n_dim == 0
        result = terms1 - scalar * terms2;
        if abs(result) < 1e-14
            result = [];
        end
        return;
    end

    result = terms1;
    for i = 1:size(terms2, 1)
        new_term = terms2(i, :);
        new_term(1) = -scalar * new_term(1);
        result = [result; new_term];
    end

    if n_dim > 0
        result = consolidate_terms_nd(result);
    end
end

function result = scale_func_nd(f, scalar)
% Scale all coefficients by scalar

    result = struct();
    result.n_dim = f.n_dim;
    result.interior = scale_terms(f.interior, scalar);

    n_faces = 2 * f.n_dim;
    result.boundaries = cell(n_faces, 1);
    for face = 1:n_faces
        result.boundaries{face} = scale_terms(f.boundaries{face}, scalar);
    end
end

function result = scale_terms(terms, scalar)
    result = terms;
    if ~isempty(result)
        result(:, 1) = result(:, 1) * scalar;
    end
end

function alpha = compute_alpha_nd(phi0, ortho_basis, proj_coeffs, a_vec)
% Compute normalization constant alpha = integral of phi_tilde_0 over interior
% (Since phi_0 = 0 on boundary, only interior contributes)

    n_dim = length(a_vec);

    % Integral of phi_0 over interior = product of a_k's (volume of hypercube)
    alpha = prod(a_vec);

    % Subtract contributions from projection (interior only)
    for i = 1:length(proj_coeffs)
        int_phi_i = integral_over_interior_nd(ortho_basis{i}, a_vec);
        alpha = alpha - proj_coeffs(i) * int_phi_i;
    end
end

function val = integral_over_interior_nd(f, a_vec)
% Compute integral of f over interior hypercube

    val = 0;
    n_dim = length(a_vec);

    for i = 1:size(f.interior, 1)
        c = f.interior(i, 1);
        exp_vec = f.interior(i, 2:end);

        term_val = c;
        for d = 1:n_dim
            term_val = term_val * a_vec(d)^(exp_vec(d) + 1) / (exp_vec(d) + 1);
        end
        val = val + term_val;
    end
end

function q = compute_expected_values_nd(phi0, ortho_basis, proj_coeffs, alpha, a_vec)
% Compute q_k = E[x_k] for k = 1, ..., n

    n_dim = length(a_vec);
    q = zeros(n_dim, 1);

    for k = 1:n_dim
        % Integral of x_k * phi_0 over interior
        % = integral of x_k over hypercube
        % = (a_k^2 / 2) * prod_{j != k} a_j
        int_xk_phi0 = (a_vec(k)^2 / 2) * prod(a_vec) / a_vec(k);

        % Subtract projection contributions
        int_xk_proj = 0;
        for i = 1:length(proj_coeffs)
            int_xk_proj = int_xk_proj + proj_coeffs(i) * integral_xk_times_f_nd(ortho_basis{i}, k, a_vec);
        end

        q(k) = (int_xk_phi0 - int_xk_proj) / alpha;
    end
end

function val = integral_xk_times_f_nd(f, k, a_vec)
% Integral of x_k * f(x) over interior hypercube

    val = 0;
    n_dim = length(a_vec);

    for i = 1:size(f.interior, 1)
        c = f.interior(i, 1);
        exp_vec = f.interior(i, 2:end);

        % Multiply by x_k means incrementing the k-th exponent by 1
        new_exp = exp_vec;
        new_exp(k) = new_exp(k) + 1;

        term_val = c;
        for d = 1:n_dim
            term_val = term_val * a_vec(d)^(new_exp(d) + 1) / (new_exp(d) + 1);
        end
        val = val + term_val;
    end
end

function delta = compute_boundary_measures_nd(ortho_basis, proj_coeffs, alpha, a_vec)
% Compute delta_i = integral of p_i over F_i for each boundary face

    n_dim = length(a_vec);
    n_faces = 2 * n_dim;
    delta = zeros(n_faces, 1);

    for face = 1:n_faces
        k = ceil(face / 2);
        a_boundary = [a_vec(1:k-1); a_vec(k+1:end)];

        % delta_face = -(1/alpha) * sum_i proj_coeffs(i) * integral of phi_i over F_face
        for i = 1:length(proj_coeffs)
            boundary_terms = ortho_basis{i}.boundaries{face};
            if ~isempty(boundary_terms)
                int_val = integrate_boundary_polynomial(boundary_terms, a_boundary);
                delta(face) = delta(face) - proj_coeffs(i) * int_val;
            end
        end
    end

    delta = delta / alpha;
end

function val = integrate_boundary_polynomial(terms, a_boundary)
% Integrate polynomial over (n-1)-dimensional boundary

    if isempty(terms)
        val = 0;
        return;
    end

    n_dim_boundary = length(a_boundary);

    if n_dim_boundary == 0
        % 0D: just return the coefficient (it's a constant)
        val = sum(terms(:, 1));
        return;
    end

    val = 0;
    for i = 1:size(terms, 1)
        c = terms(i, 1);
        exp_vec = terms(i, 2:end);

        term_val = c;
        for d = 1:n_dim_boundary
            term_val = term_val * a_boundary(d)^(exp_vec(d) + 1) / (exp_vec(d) + 1);
        end
        val = val + term_val;
    end
end
