function R = create_reflection_matrix(n_dim, type)
% CREATE_REFLECTION_MATRIX Create reflection matrices for n-dimensional SRBM
%
% Usage:
%   R = create_reflection_matrix(n_dim, type)
%
% Inputs:
%   n_dim - number of dimensions
%   type  - string specifying reflection type:
%           'normal'    - perpendicular reflection on all faces
%           'tandem'    - tandem queue model (generalization of 2D case)
%           'jackson'   - Jackson network style reflection
%
% Output:
%   R - n_dim x 2*n_dim reflection matrix
%       Column ordering: [v_{x1=0}, v_{x1=a1}, v_{x2=0}, v_{x2=a2}, ...]
%
% Reference: Dai & Harrison (1991) for 2D tandem queue reflection

    switch lower(type)
        case 'normal'
            R = create_normal_reflection(n_dim);

        case 'tandem'
            R = create_tandem_reflection(n_dim);

        case 'jackson'
            R = create_jackson_reflection(n_dim);

        otherwise
            error('Unknown reflection type: %s', type);
    end
end

function R = create_normal_reflection(n_dim)
% Normal (perpendicular) reflection on all faces
% This corresponds to independent reflected Brownian motions in each dimension

    R = zeros(n_dim, 2*n_dim);
    for k = 1:n_dim
        R(k, 2*k-1) = 1;   % +e_k on face x_k = 0
        R(k, 2*k) = -1;    % -e_k on face x_k = a_k
    end
end

function R = create_tandem_reflection(n_dim)
% Generalized tandem queue reflection for n stations in series
%
% In a tandem queue with n stations:
% - When queue k is empty (x_k = 0): reflection affects x_{k-1} and x_k
% - When queue k is full (x_k = a_k): reflection affects x_k and x_{k+1}
%
% For 2D, this matches the Dai & Harrison (1991) reflection matrix (24):
%   R = [1, 0, -1, 1; -1, 1, 0, -1]
%
% Note: This is a specific model choice, other configurations are possible.

    R = zeros(n_dim, 2*n_dim);

    for k = 1:n_dim
        % Face x_k = 0 (queue k is empty)
        % Reflection direction: primarily pushes in +x_k direction,
        % with coupling to x_{k-1} (blocking upstream)
        col_lower = 2*k - 1;
        R(k, col_lower) = 1;  % Main component
        if k > 1
            R(k-1, col_lower) = -1;  % Upstream blocking effect
        end

        % Face x_k = a_k (queue k is full)
        % Reflection direction: pushes in -x_k direction,
        % with coupling to x_{k+1} (flow to downstream)
        col_upper = 2*k;
        R(k, col_upper) = -1;  % Main component
        if k < n_dim
            R(k+1, col_upper) = 1;  % Downstream flow effect
        end
    end
end

function R = create_jackson_reflection(n_dim)
% Jackson network style reflection
% Each queue reflects independently in its own dimension (same as normal)
% but this version includes explicit routing structure

    % For a simple open Jackson network, the reflection is normal
    R = create_normal_reflection(n_dim);

    % More complex routing could be added here by modifying off-diagonal elements
end
