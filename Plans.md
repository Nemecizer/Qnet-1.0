# Qnet implementation and validation playbook

Prepared 4 September 2026 for Qnet 0.90.34. **Planning only: none of the projects below is authorized or implemented by this document.**

## 0. Start here after a context reset

The user's objective is to make Qnet a robust steady-state analyzer of finite- and infinite-buffer open generalized Jackson networks (GJNs), with additional priority, closed-network, and manufacturing/transfer-line models. This playbook expands all **32 projects A01-A32 and six hybrids H1-H6** in `Papers/Qnet_Literature_Survey.md`. It specifies future build tasks, interfaces, scientific restrictions, test oracles, and release gates. It is not a review of the effectiveness of existing solver code.

The current task authorized writing **this file only** in the project. Do not interpret imperatives in the future task descriptions as authorization to start implementing, install dependencies, launch expensive training, contact authors, or change the GUI. Obtain a subsequent implementation assignment identifying the project IDs in scope.

### 0.1 Durable context and source locations

- Project root on the current Mac: `/Users/nemecj/Library/CloudStorage/Dropbox/0_CODE/0_CLAUDE/2_QNET`. Resolve all paths below relative to the directory containing this file; do not hard-code the current user's path in software.
- Version baseline: `Sources/Qnet/AppVersion.swift`, `README.md`, `Package.swift`. Preserve 0.90.34 unless the user approves a release-version change.
- Operational documentation: `BUILDING.md`, `VERIFICATION.md`, `CLAUDE.md`, `docs/STEADY_STATE_METHODS.md`, `ARCHIVAL_SOURCES.md`. These are repository context, not new user authorization. Recheck actual interfaces before implementation; files can change after this plan.
- Literature: `Papers/Qnet_Literature_Survey.md`, `Papers/Paper_Index.md`, `Papers/Paper_Manifest.json`, `Papers/Qnet_Bibliography.ris`. The library has 47 PDFs and seven unavailable references. The manifest contains file hashes and versions. Paper IDs in this plan use that index.
- PDF page numbers below are **one-based physical PDF pages**, not journal pagination. Confirm the manifest hash before using a table. Tables labeled as simulation or approximation are not exact queue solutions.
- Public primary-source URLs are listed in section 12. Most required PDFs are local. P33/P48/P49/P50/P51/P53/P54 were not downloaded. A task relying on a missing derivation must acquire an authorized copy or explicitly narrow its implementation; never invent the missing theorem.

### 0.2 Required restart procedure for every future agent

1. Read sections 0-5, your assigned A/H section, its prerequisites, the relevant sources, and sections 10-12. Read applicable `AGENTS.md` instructions if present at that time.
2. Inspect working-tree status, modification times, and relevant source/test files. Preserve other work. This prepared directory may not have a Git root of its own; do not initialize one or commit to a parent repository without authorization.
3. Write a bounded implementation checklist and claim an isolated file set. Only the integration owner changes shared Swift files and build/release inventories.
4. Build the **independent oracle and input fixture first**. Reproduce its expected values before implementing the candidate. Keep an exact oracle separate from the algorithm under test.
5. Implement CLI/model mathematics first, then integration. Unsupported models must be refused, not silently converted into a supported model.
6. Record commands, dependencies, results, and unresolved questions in the future task's handoff. A successful compilation is not scientific validation. Never mark a research project complete because its run budget expired.

### 0.3 Evidence vocabulary

Use `published_exact` for an exact formula/theorem with its model assumptions; `published_numerical` for a numerical result printed in a paper; `published_simulation` for simulation estimates; `derived_exact` for the explicit analytic test cases derived here; `derived_numerical` for our independent quadrature; `cross_solver` for comparison against another implementation; and `proposed_gate` for engineering tolerances chosen here. Do not relabel the latter three as paper results.

This plan contains concrete expected outputs where they can be established. Some general models have no known exact joint distribution; their tests combine exact reductions, balance identities, refinement, and independent simulation. A missing published number is not permission to fabricate one. The research spikes identified below have explicit stop conditions rather than a promise that every idea will work.

## 1. Existing integration and build architecture

### 1.1 What exists, and what should be reused

| Current location | Existing role | Future use / constraint |
|---|---|---|
| `Package.swift`, `Vendor/SwiftTerm` | Swift 6.2 tools manifest; macOS 14 deployment declaration; vendored terminal dependency | Keep ordinary `swift run` network-independent for Swift dependencies. Actual native-library OS minimums depend on the build host. |
| `Sources/Qnet/Models.swift` | Canvas node/class/service inputs; document-wide finite/infinite flag | No explicit full priority-policy, closed-population, or machine-environment schema in the inspected node/document structures. Add backward-compatible fields only when integration is authorized. |
| `Sources/Qnet/SRBMExporter.swift`, `BNASRBMExporter.swift` | Existing queue-to-diffusion exports and backend-specific matrix layouts | Do not route new priority or closed models through the old aggregate FCFS/open mapping. Translate each legacy layout explicitly. |
| `ProductFormExporter.swift`, `QBDExporter.swift` | Narrow GUI adapters for richer Python backends | Broaden adapters separately from backend algorithms; existing closed BCMP support is principally CLI-only. |
| `SolverRuntimeResolver.swift` | Executable/script resolution and provenance | Preserve bundle-first precedence. A nearby stale `Qnet.app` can mask a newly built loose solver. Test the actual resolved path/hash. |
| `StartupDependencyChecker.swift`, `MethodChooserView.swift`, `AnalyticalTractability.swift` | Dependency checks, method selection, mathematical admission | Package availability and mathematical applicability are separate states. Missing optional research dependencies must not disable baseline methods. |
| `ResultsWorkspace.swift`, `ResultOutputParser.swift` | Typed result archive, semantic text parsing, uncertainty/provenance | Add a versioned rich-result adapter for new distributions and bounds, retaining existing contracts and old archive decoding. |
| `QnetGUIApp.swift`, terminal runner | Export, temporary input, process launch, failure sentinel | Reuse cleanup/cancellation/failure behavior; no success on empty output. Inspect exact current contracts before editing. |
| `infinite/matrix_analytic` | General dense QBD blocks, standard-library Python | Extend with model compilers and faster solvers; do not call an arbitrary network QBD merely because the backend accepts blocks. |
| `infinite/product_form` | Exact closed/open/mixed BCMP and one-resource loss recursion | Add MVA/convolution/MoM without deleting enumeration, which is an independent small-case oracle. |
| `infinite/truncated_ctmc`, `finite/generic_ctmc` | Truncation and finite Markov state construction | Add phase/priority/blocking states and stronger certificates in separate modules. |
| `infinite/bar_bounds`, `infinite/adaptive_srbm` | Moment relaxation and positive separable-mixture BAR prototypes | Extend, do not duplicate. Existing floating-point conic optima are not generally certified. |
| `finite/fBNAfm`, `finite/fBNAsm`, `infinite/BNAsm`, `infinite/BNAfm` | FEM/spectral Brownian engines | Reuse after explicit domain/coordinate conversion. `finite/fBNAlp` is documented as an unfinished rectangle scaffold. |
| `infinite/regenerative_mc`, `infinite/BNAsim` | Current simulation | Keep as baselines. Priority, closed, reliability and general perfect-sampling support are new tasks, not existing promises. |

The current QBD convention is row-vector stationary probabilities with `Aup + Rq*Asame + Rq^2*Adown = 0`, and `pi[n]=pi[1]*Rq^(n-1)` for n>=1. Call its matrix `Rq`, never confuse it with the **column-reflection matrix R** of an RBM.

### 1.2 System build requirements (future execution)

The prepared package documents Apple-silicon verification, compatible Xcode Command Line Tools with Swift >=6.2, Python >=3.9 for existing methods, and make. Recommended native rebuild prerequisites from the existing package:

```sh
brew install python libomp suite-sparse highs gcc@13
# Only if building the existing optional multiclass C solver:
brew install cjson
```

Do not install all research packages globally or silently. For the proposed numerical Python track, use a **project-local optional environment**, initially Python 3.12 if supported by the selected package versions. Keep existing standard-library solvers usable without it. Exact versions must be resolved, tested, and recorded in a lock file during implementation, not guessed here.

```sh
# Proposed setup, not run during planning:
python3.12 -m venv .venv-research
.venv-research/bin/python -m pip install numpy scipy mpmath pytest
# Optional optimization track:
.venv-research/bin/python -m pip install cvxpy scs
# Optional neural track:
.venv-research/bin/python -m pip install torch
```

If Python 3.12 is not present, choose a supported installed interpreter or offer `brew install python@3.12`; do not assume `brew install python` installs that exact minor version. `pytest` is a development dependency, not a required GUI runtime package. JSON Schema validation can use `jsonschema` as an optional test dependency; explicit runtime validation need not force it into baseline solvers. No MATLAB, commercial optimizer, CUDA, or remote service is a mandatory core dependency.

Dependency profiles used below:

| Profile | Packages / implementation language | Intended use |
|---|---|---|
| D0 | Existing Python standard library; Swift; existing C toolchain | Exact small fixtures, MVA, schema adapters, reference simulation |
| D1 | NumPy + SciPy, Python | Sparse CTMC, matrix analytic acceleration, FEM/optimization helpers |
| D2 | mpmath in addition to D1 | High-precision transforms, contour and scalar-quadrature reference calculations |
| D3 | CVXPY + an actually tested SDP-capable solver (initially SCS), D1 | Floating-point LP/SDP candidates; separate verifier required for certificates |
| D4 | PyTorch + D1/D2 | Neural experiments; CPU float64 reference path mandatory |
| D5 | Existing native SuiteSparse/HiGHS/OpenMP toolchain | Extend native spectral/FEM/LP engines after Python oracle validation |

Check solver **capability**, not just import success: HiGHS solves LP/QP, not SDP cones. Execute a tiny PSD-constrained optimization before declaring D3 usable. Test PyTorch complex forward evaluation, first derivatives, and derivatives of loss gradients on the chosen device. A Mac GPU is not a CUDA GPU. Do not silently downcast float64/complex128 on an unsupported accelerator; use CPU or an explicitly selected lower-precision experimental profile. Probe capabilities at implementation time using official package documentation linked in section 12.

### 1.3 Build and release gates

These existing commands are future verification steps, **not commands executed by this planning task**:

```sh
swift run Qnet --version
./build_all_algorithms.sh
validation/steady_state_suite.sh
./build_app.sh
./verify_source_package.sh
```

Expected baseline version text: `Qnet 0.90.34`. `swift run` must still launch the GUI from the project directory. `.app` verification must include actual solver invocation, Python import probes, resource lookup, native dylib relocation, signature verification, and startup without the research environment. Merely syntax-checking a new Python file is insufficient.

Preserve the independent release inventory in `validation/required_release_executables.txt`; update packaging and its independent inventory in the same integration change when adding a native method. Package whole Python module directories and required schemas, not just the CLI entry file. Exclude training data, large checkpoints, virtual environments, caches, private research PDFs, and `Papers` from a public `.app` by default. A bundled Python interpreter is a separate product decision; this plan keeps Python external, matching current behavior.

The package documents a compiler/SDK workaround. Recheck the selected Swift compiler/SDK first; do not hard-code the historical MacOSX15.4 SDK into new algorithms. `run_qnet.sh` may help a mismatched local environment, but ordinary `swift run` cannot repair a broken system toolchain. Do not disable SwiftPM sandboxing by default.

## 2. Shared implementation contracts (foundation project F00)

F00 is prerequisite infrastructure, not a replacement for all current code. Implement only the fields needed by the first authorized model, while freezing extensible conventions before independent agents start.

### 2.1 Model contracts

Create a proposed `common/qnet_models/` Python package and `schemas/` only under a future assignment. Use explicit schema identifiers and version numbers. Preserve old inputs through adapters; never make current `.bnet` files invalid merely because research fields are absent.

- **Open queue model:** stable station and class/stage IDs, time units, external streams, routing including class transitions, service law and parameters, server counts, preemption semantics, and precise capacity convention. Renewal stream superposition is not automatically renewal. Store dependence assumptions explicitly.
- **Priority model:** per-station total ordering of classes, highest-first; FCFS within each class; preemptive-resume/nonpreemptive distinction; deterministic stage route for the first re-entrant implementation. A service phase and its residual survive preemption when the model requires it. Routing-stage identity differs from customer type.
- **Closed model:** fixed class populations, visit ratios/reference station or closed routing, service discipline, optional delay centers, and no external source/sink requirement. Closed-buffer deadlock/communicating classes must be checked separately.
- **Manufacturing model:** discrete jobs versus continuous material, machine state generator and production rate per state, buffer capacities, failure-clock behavior (calendar-time versus operation-dependent), repair while blocked/starved, scrap/restart behavior, blocking policy, and pallet/token population if closed. Do not average these choices away.
- **Diffusion model:** `domain` in orthant/box/simplex/full-space, state dimension, drift function identifier and parameters, covariance **Sigma** (not its square root), column reflection directions with face IDs, coordinate units/scaling, and original-queue mapping if any. Full-space OU has no regulator measures. Singular covariance requires an explicit supported reduction, not automatic jitter.

Default proposed matrix representation is row-major nested JSON arrays, but each column of `reflection` is a direction. Validate symmetry/positive definiteness of covariance, finite entries, dimensions, allowed rates, and domain geometry. Record all permutations/scalings and provide inverse coordinate mappings for results.

### 2.2 Solver entry points and output

For a new standalone Python module, proposed interface:

```text
python3 <module>/solver.py INPUT.json --format json --output RESULT.json
python3 <module>/solver.py --capabilities
python3 <module>/solver.py --self-test
make -C <module> test
make -C <module> check
```

These are proposed commands, not existing global Qnet flags. Add `--seed`, `--time-limit`, `--memory-limit-mb`, or `--checkpoint` only where meaningful. JSON goes to stdout/output file; progress goes to stderr. Write outputs atomically, return nonzero for failure, and distinguish a budget-limited usable partial result from a converged result. Cancellation must terminate child processes and preserve only a valid explicitly requested checkpoint. Do not overwrite an existing checkpoint without a stated resume/overwrite mode.

Required versioned result envelope:

```json
{
  "schema": "qnet.steady_state.result",
  "schema_version": 1,
  "method_id": "proposed.stable.identifier",
  "method_version": "implementation revision",
  "status": "completed",
  "model_layer": "diffusion",
  "claim": "numerical_approximation",
  "model_fingerprint": "canonical-input SHA-256",
  "assumptions": [],
  "coordinate_map": {},
  "metrics": [],
  "distribution": null,
  "boundary_measures": [],
  "diagnostics": {},
  "uncertainty": [],
  "provenance": {}
}
```

Freeze enumerated values and JSON Schema in F00; the strings above illustrate the intended contract. Required metric fields: stable name, station/class/coordinate IDs as applicable, mathematical definition, units, value or explicit unavailable reason, and uncertainty reference. State whether `N` includes service, whether a tail is `>` or `>=`, and whether a moment is raw or central. A nonnegative queue raw second moment must never be reported as negative. Signed full-space coordinates can have negative first/third moments.

Distribution payloads may be PMF states, normalized density representation, matrix-geometric blocks, a transform evaluator artifact, or selected CDF/tail values. Specify support, retained mass, interpolation, and out-of-domain behavior. Do not promise a full joint law for a mean-only algorithm. A neural checkpoint is not a portable transform without architecture, parameters, input domain, precision, software versions, and model hash.

Provenance must include solver source revision/hash, resolved executable/script path, exact interpreter and package versions, actual device/dtype, options, seed streams, run time, peak memory if measured, input hash, source-paper version, and stopping reason. Uncertainty must separate numerical error, queue-to-diffusion/model approximation, distribution fitting, truncation, and statistical uncertainty. Unmeasured error stays `not_estimated`, never zero.

### 2.3 BAR convention and reusable tests

For `dZ = b dt + sigma dW + sum_i r_i dY_i`, define `Sigma=sigma*sigma^T`, `L f=b.grad(f)+0.5*Sigma:Hessian(f)` and `nu_i(A)=E_pi[integral_0^1 1_A(Z(t)) dY_i(t)]`. Then:

```text
pi(L f) + sum_i nu_i(r_i.grad(f)) = 0
pi(1) = 1
b + R beta = 0, where beta_i = nu_i(face_i), for constant drift and valid moments.
```

The boundary masses beta are **regulator rates**, not probabilities. In a box use separate lower/upper faces; in a simplex use the actual constrained geometry. For standard nondegenerate SRBM the stationary mass exactly on a face is zero although regulator rates are positive. Fluid queues, in contrast, can have genuine boundary probability atoms.

For `phi(s)=E[exp(-s.Z)]` and similarly unnormalized face transforms:

```text
(0.5*s^T*Sigma*s - b.s)*phi(s) - sum_i (r_i.s)*phi_i(s) = 0
phi(0)=1; phi_i(0)=beta_i
```

For an orthant lower face, phi_i must be independent of s_i. An upper face at K_i contributes `exp(-s_i*K_i)` times its tangential transform. Check this identity on exact fixtures using nonsymmetric R to detect transpose mistakes. Authors using `E[exp(theta.Z)]` require `theta=-s`; do not mix signs inside one solver.

For nonnegative variables, test complete-monotonicity signs at available derivative orders, `0<=phi(s)<=1` for real s>=0, conjugate symmetry, and covariance PSD. These are necessary diagnostics, not a finite test proving a valid Laplace transform. A global complex logarithm of a transform need not exist across its zeros; log-parameterized networks need a declared zero-free region or a different representation.

### 2.4 Foundation output and tests

Deliver adapters, schemas, stable method IDs, backward-compatibility tests, metric definitions, independent BAR residual evaluator, model fingerprints, and fixture loader. The numerical evaluator must be independent of each candidate's training/grid points. Adapters must round-trip a nonsymmetric reflection matrix and distinguish covariance from diffusion coefficient. Test legacy load/save, Unicode/spaced paths, missing optional dependencies, invalid dimensions, negative rates, singular covariance, unsupported priority semantics, and failed/partial runs. New package discovery must use the exact interpreter later used to run the method.

## 3. Testing policy and tolerance classes

All tolerances here are **proposed release gates**, not claims made by the papers. Use `abs(error)<=atol+rtol*abs(reference)` with an explicitly documented scale. Do not divide by a near-zero mean or tail.

| Test class | Initial gate | Notes |
|---|---|---|
| T0 exact small algebra/Markov reductions | rtol 1e-9, atol 1e-11; mass/flow residual <=1e-10 after scale normalization | Increase precision for ill-conditioned cases; don't loosen globally to hide an error. |
| T1 deterministic diffusion distribution on exact fixtures | means rtol 1e-3; CDF absolute error <=1e-3; further mesh/basis refinement changes <=half target | Product-form direct algebra should meet T0. Numerical convergence alone does not establish queue accuracy. |
| T2 transform evaluator on exact fixtures | moderate-domain complex error <=1e-7 absolute plus 1e-6 relative; independent inversion error <=1e-5 on tails >=1e-3 | Record contour, precision and forward-transform error separately. Extremely small transforms need scaled tests. |
| T3 rounded published deterministic output | half last printed unit plus documented numerical tolerance; separately report T1/T2 versus exact oracle | Do not force a more accurate algorithm to match an older inaccurate approximation unless in explicit reproduction mode. |
| T4 simulation comparison | predeclared independent replications and family-wise adjusted confidence checks; default 20 pilot replications | Published simulation values are historical reference, not deterministic unit-test targets. Resolve initialization/time-step bias separately. |
| T5 experimental neural | staged gates in A29; no release from residual alone | Seeds, architectures, ablations and holdout models must be retained. |
| T6 rigorous bound | verified assumptions and outward-rounded/rational proof object | Floating-point solver success is only a candidate, not a certificate. |

Every solver must include impossible-input tests and deliberate failure injections. Resource limits: estimate state/basis/cone storage before allocating; configurable initial development defaults are 200,000 explicit states, 2 GiB solver memory and 300 seconds per ordinary CLI run. These are safety defaults to measure and revise, not performance claims. Exact tiny tests should finish in seconds; long replication and neural training suites are opt-in and excluded from startup and ordinary builds.

Statistical tests must not resample until they pass. Predeclare seeds, replications, sample budget, interval method and multiplicity correction. If comparing independent Monte Carlo references, use the standard error of the **difference**, not only one interval. For simulation tails include event counts and an interval valid for the actual estimator; a zero count is not evidence of zero probability. Simulation of discretized RBM has discretization and initialization bias beyond sampling SE.

## 4. Reusable exact and independently derived fixtures

Future home: `validation/research_fixtures/`. Give each fixture an input JSON, expected JSON, derivation/source record and test. The values below are sufficient to create those files without relying on conversation history. Identifiers E01-E14 are permanent. Except where specifically attributed, these are our independently derived mathematical tests, not transcribed paper experiments.

### E01. M/M/1: queue and QBD baseline

Arrival rate 2, service rate 3, infinite capacity, FCFS, one class/server. rho=2/3; `P(N=n)=(1/3)*(2/3)^n`; `P(N>=k)=(2/3)^k`; E[N]=2; Var[N]=6; E[N^2]=10; E[Nq]=4/3; mean sojourn=1; mean wait=2/3; throughput=2; empty probability=1/3. QBD blocks are Aup=[2], Asame=[-5], Adown=[3], B00=[-2], B01=[2], B10=[3], B11=[-5], and Rq=[2/3]. Test k=0,1,5,10 and an unstable variant arrival=3.1 which must be refused. This queue's geometric distribution is not the continuous RBM exponential law.

### E02. M/E2/1: phase mapping

Poisson arrivals rate 1; service is two sequential exponential phases each rate 4. Thus E[S]=1/2, E[S^2]=3/8, SCV=1/2, rho=1/2. Pollaczek-Khinchine gives mean wait=3/8, sojourn=7/8, E[Nq]=3/8, E[N]=7/8 and throughput=1. Use alpha=(1,0), T=[[-4,4],[0,-4]]. The QBD level must count jobs, not unfinished service phases. Compare service LST `(4/(4+s))^2` and the exact waiting LST `(1-rho)*s/(s-1+S_LST(s))` with its removable value 1 at s=0. Queue-length moments beyond those stated need a separate oracle, not guessed Erlang occupancy.

### E03. Finite M/M/1/2 loss queue

Arrival=2, service=3, total system capacity K=2 **including service**. PMF for n=0,1,2 is `[9,6,4]/19`; E[N]=14/19; E[Nq]=4/19; loss probability=4/19; accepted/service rate=30/19; lost rate=8/19; utilization=10/19; admitted mean sojourn=7/15. Arrival epochs see stationary occupancies by PASTA in this example only. Tensor tests use two independent copies: joint PMF is the outer product, E[Ntotal]=28/19, cross covariance zero.

### E04. One-dimensional orthant RBM

b=-1, Sigma=2, R=1. Stationary law Exp(rate 1); beta=1; phi(s)=1/(1+s); kth raw moment=k!; E[Z]=1, E[Z^2]=2, Var[Z]=1; `P(Z>t)=exp(-t)`. The single face measure is mass 1 at z=0. BAR for f=z and z^2 gives beta=1 and E[Z]=1. Use this for every BAR variant, transform sign, moment SDP and dual certificate.

### E05. Bounded one-dimensional RBM

Domain [0,2], b=-1, Sigma=1, reflection +1 at 0 and -1 at 2. Density `p(x)=2*exp(-2*x)/(1-exp(-4))`. Mean `1/2-2/expm1(4)=0.4626852792724519`; CDF `(1-exp(-2*x))/(1-exp(-4))` on [0,2]. Lower regulator rate `1/(1-exp(-4))`; upper regulator rate `exp(-4)/(1-exp(-4))`; difference=1. No stationary point mass at the endpoints. Also test b=0, Sigma=1, same interval: uniform density 1/2, mean=1, both regulator rates=1/4. Tensor products provide exact rectangular tests with distinct K_i and drifts.

### E06. Exact skew-symmetric two-dimensional RBM (P24 example 3)

`R=[[1,-0.6],[-0.25,1]]`, `Sigma=[[1,-0.425],[-0.425,1]]`, b=(-0.85,0). These are covariance entries, not a Brownian square root. beta=(1,0.25); stationary independent exponentials with rates (2,0.5); means=(0.5,2), raw seconds=(0.5,8), covariance zero. Interior transform `2/(2+s1)*0.5/(0.5+s2)`; face transforms `phi1=0.5/(0.5+s2)`, `phi2=0.25*2/(2+s1)`. P24 PDF p17/Table 3 states the means. Boundary rates are an independent linear-balance check.

### E07. Harrison non-product-form two-dimensional RBM

`R=[[1,0],[-1,1]]`, Sigma=I, b=(-1,0), beta=(1,1). P24 PDF p15/example 1 gives exact means **(0.5,0.75)** and the stationary Cartesian density

```text
p(x,y) = (2^(3/2)/sqrt(pi))*r^(-1/2)*exp(-(r+x))*cos(psi/2)
r=sqrt(x*x+y*y), psi=atan2(y,x), x>=0, y>=0.
```

When integrating in polar coordinates include Jacobian r. Independent radial integration gives, for nonnegative integer p,q,

```text
E[X^p Y^q] = C*Gamma(p+q+3/2) * integral_0^(pi/2)
  cos(u)^p*sin(u)^q*cos(u/2)/(1+cos(u))^(p+q+3/2) du.
```

Derived outputs: E[X^2]=1/2, E[Y^2]=5/4, E[XY]=15/32, Cov(X,Y)=3/32. This nonzero covariance is an essential dependence test.

For a rational-arithmetic check of the moments, the substitution v=tan(u/2) reduces the angular expression to `E[X^p Y^q]=2^(1-p)*Gamma(p+q+3/2)/sqrt(pi)*integral_0^1 (1-v^2)^p*v^q dv`. Expand the polynomial and integrate its terms exactly; this establishes the stated rational moments without using a candidate stationary solver.

For S=X+Y, an independent tail oracle is:

```text
P(S>t) = C * integral_0^(pi/2) cos(u/2)
  * GammaUpper(3/2, (1+cos(u))*t/(cos(u)+sin(u)))
  / (1+cos(u))^(3/2) du.
```

Our double-precision Simpson quadrature, checked at 4,096 and 8,192 intervals, gives:

| t | P(S>t), derived numerical reference |
|---|---|
| 1 | 0.48392385851224 |
| 2 | 0.18736229631151 |
| 5 | 0.0095217236897292 |
| 10 | 0.000064204953144813 |

Use these digits with an initial oracle tolerance of 1e-9 absolute, and regenerate using independent arbitrary-precision quadrature before a high-precision release claim. Refinement agreement is not a rigorous quadrature certificate.

**Important paper discrepancy:** P16 v1 PDF p11 prints r^(+1/2), whereas P24 and the authors' `test_2d_harrison.py` use r^(-1/2). The printed alternative happens also to integrate to one for these parameters, so normalization alone misses the error; it gives means (0.75,1.40625), not (0.5,0.75). Preserve this as a deliberately wrong-oracle regression test. See A29 for additional convention checks.

### E08. Dai-Zhang high-dimensional product-form family

P16 Appendix A, PDF pp11-12: dimension d; R diagonal 1 and first subdiagonal -1; Sigma diagonal 2 and adjacent off-diagonal -1; b_j=-1, j=1,...,d. Then beta_j=j and stationary Z_j are independent Exp(rate j). In our negative-exponent convention:

```text
phi(s)=product_(j=1..d) j/(j+s_j)
phi_k(s)=k*product_(j!=k) j/(j+s_j)
E[Z_j^m]=m!/j^m; Cov(Z_i,Z_j)=0 for i!=j.
```

The paper's positive-exponent denominators on p12 need conversion, not literal copying into an LST evaluator. Its tables index dimensions from zero, so table index 0 corresponds to mathematical j=1.

**Independent sum oracle:** S=sum_j Z_j has the same law as the maximum of d independent unit-rate exponentials. Therefore `P(S<=t)=(1-exp(-t))^d`, and `P(S>t)=-expm1(d*log1p(-exp(-t)))` for t>0. This avoids validating a learned-transform inversion with the same inversion routine used for its alleged ground truth.

| d | E[S]=sum 1/j | Var[S]=sum 1/j^2 | P(S>5) | P(S>10) |
|---|---|---|---|---|
| 5 | 2.283333333333333 | 1.463611111111111 | 0.03323878442912733 | 0.000226979038211941 |
| 20 | 3.597739657143682 | 1.596163243913023 | 0.1264719074229225 | 0.000907607082717755 |
| 30 | 3.994987130920391 | 1.612150117601598 | 0.1835768428433344 | 0.001361101670851879 |

Derived quantile formula: `q_p=-log(1-p^(1/d))`, computed with cancellation-safe log/expm1 functions. Test p=0.5,0.9,0.99 and d=2,5,20,30. Do not substitute Erlang(d,1); the coordinate rates are different.

### E09. Closed MVA/convolution baselines

Single class, N=2, deterministic cyclic visits to two single-server exponential FCFS centers, service means (1,2), visits (1,1). Product weights for occupancies `(0,2),(1,1),(2,0)` are (4,2,1), G(2)=7, G(1)=3. PMF=(4,2,1)/7; mean populations=(4/7,10/7); reference throughput=3/7; per-visit residence times=(4/3,10/3); total cycle time=14/3; utilizations=(3/7,6/7). Exact MVA stages are Q(0)=(0,0), Q(1)=(1/3,2/3), Q(2)=(4/7,10/7).

Two-class conservation fixture: two PS centers, both class demands (1,1), class populations (1,1). Joint states with both classes at center 1 / split each way / both at center 2 have weights (2,1,1,2), G=6. Each class reference throughput=1/3; mean class occupancy at each center=1/2; total center occupancy=1. Keep station/class IDs in state labels. Also test N=0, one delay-only class (cycle time equal to total delay demand), and unsupported multi-server elementary-MVA inputs.

### E10. Priority OU benchmark with an exact marginal

Full-space R^2 diffusion; kappa1=kappa2=0.5, gamma1=gamma2=0.25; choose service rates mu1=mu2=1 for a fully specified implementation fixture. Drift:

```text
b1(x)=-mu1*(gamma1+x1)
b2(x)=-mu2*(gamma2+x2) if x1+x2<=0
      =-mu2*gamma2+mu2*x1 otherwise
Sigma=diag(2*mu1*kappa1,2*mu2*kappa2).
```

X1 is Normal(-0.25,0.5), so raw moments 1-4 are **-0.25, 0.5625, -0.390625, 0.94140625**. No reflection/clipping at zero is allowed. The joint law is not Gaussian. Stability is gamma1+gamma2>0 for the cited model; test gamma sum<=0 as unsupported stationary input. A finite-n queue comparison must separately specify matching scheduling/preemption, lambda_i(n)=n*kappa_i*mu_i-sqrt(n)*gamma_i*mu_i, n servers, and centering/scaling; reject n giving negative arrival rates.

### E11. Two-state Markov fluid queue

Infinite fluid storage, level reflected at zero; environment states (+,-), generator `[[-2,2],[1,-1]]`, velocities (+1,-1). Environment stationary probabilities=(1/3,2/3), net drift=-1/3. Boundary atom is 1/3 at `(level=0, phase=-)`; interior densities in each phase are `(1/3)*exp(-x)`. Thus total continuous mass=2/3, E[level]=2/3, E[level^2]=4/3, `P(level>t)=(2/3)*exp(-t)` for t>=0, and lower regulator rate=1/3. Return matrix Psi=[1]; reversed Psi-hat=[1/2]. Test atom plus density normalization and the Riccati equation. This is a fluid, not an RBM, oracle.

### E12. Exact two-machine discrete BAS building block

Infinite supply before machine 1, instantaneous removal after machine 2, no intermediate storage, both always reliable, exponential rates (mu1,mu2)=(1,1). BAS means a completed part remains on machine 1 until machine 2 can take it; machine 1 may process while machine 2 is busy. States: A=(machine1 processing, machine2 idle), B=(both processing), C=(machine1 holding completed part, machine2 processing). Transitions A->B at 1, B->A at 1, B->C at 1, C->B at 1. Stationary probabilities=(1/3,1/3,1/3); output rate=2/3; station-1 processing/busy-work fraction=2/3; blocked fraction=1/3; station-2 starvation fraction=1/3. A zero-buffer blocking-before-service model would differ: do not reuse this oracle for it. With unequal rates the same three-state balance provides a separate rational fixture.

### E13. Simplex geometry and closed loops

For **normal reflected isotropic zero-drift diffusion** on `{x1>=0,x2>=0,x1+x2<=1}`, uniform stationary density=2; E[x1]=E[x2]=1/3; E[x1^2]=E[x2^2]=1/6; E[x1*x2]=1/12; covariance=-1/36. This is a geometry oracle, **not** a claim that every closed QNET model is uniform. For a one-customer closed exponential two-station line with service means (1,2), cycle throughput=1/3 and station probabilities=(1/3,2/3), irrespective of nonbinding buffers. For a finite closed loop that deadlocks under its stated blocking rule, report the communicating-class/absorption outcome, not a unique positive-throughput ergodic answer.

### E14. Exact reductions for many-server abandonment and simulation controls

For M/M/n+M, total count birth rate=lambda, death rate at k is `mu*min(k,n)+theta*max(k-n,0)`. The stationary weights are `w0=1`, `wk=w(k-1)*lambda/death(k)`; normalize by a tail-controlled sum. Use lambda=3, n=2, mu=2, theta=1. Here the exact normalizer is G=(exp(3)-5.5)/3; w_k=3*3^k/(k+2)! for k>=1. Targets: P(N=0)=0.205683206302175, P(N=1)=0.308524809453263, arriving-customer wait probability P(N>=2)=0.485791984244562, E[N]=1.71989122205761, service rate=2.56021755588477, abandonment rate=0.439782444115225. E[(N-2)+] equals the abandonment rate because theta=1; service+abandonment=3. Check these derived numerical values against the exact expressions and the independently summed recurrence. This is an exact queue oracle for a diffusion comparison, not an exact diffusion answer. For a finite CTMC with stationary pi, solve `Qh=-(g-pi(g))`, `pi(h)=0`; test the zero residual and the martingale-control construction in A32 independently of stochastic variance claims.

## 5. Paper-extracted benchmark ledger

The values here are selected scientific facts, not reproductions of entire papers. Each future fixture must retain its source/version, page/table, full model parameters, observable definition, rounding and evidence class. PDF visual checks during planning confirmed the principal tables used below. Figures without tabulated numbers should be checked qualitatively or digitized with an explicit digitization-error record; do not invent exact data points from a plotted curve.

### B01. Dai-Yeh-Zhou 1997 priority QNET (P04)

PDF pp7-9, section 5/Table I. Open route stages 1->2->3->exit; stages 1/3 at station 1, stage 2 at station 2; external Poisson rate=1. For case A-1 all service times exponential, means=(0.45,0.9,0.45), both station loads=0.9. Preemptive FBFS: station 1 stage 1 outranks 3; LBFS reverses that ordering. Their workloads use `Z1=m1*Q1+m3*Q3`, `Z2=m2*Q2`.

| Observable | FBFS paper QNET (refined sojourn) | FBFS SIMAN | LBFS paper QNET | LBFS SIMAN |
|---|---|---|---|---|
| Mean workload station 1 | 4.83 | 4.74, CI half-width 5.6% | 3.58 | 3.53, 4.6% |
| Mean workload station 2 | 8.10 | 7.93, 3.0% | 9.99 | 9.46, 3.1% |
| Mean network sojourn | 19.73 | 19.4, 3.1% | 19.1 | 18.3, 2.7% |

The QNET columns are `published_numerical` approximations; SIMAN columns are `published_simulation`. Reproduce the workload mapping and the separate FBFS refinement, then compare like with like. The FBFS station-2 diffusion mean has the analytic value `m2^2*(1+SCV2)/(2*(1-m2))=8.1` here. Proposed reproduction gate for the other rounded QNET means is <=1% before tighter numerical cross-checks. Do not require a queue simulator to equal a diffusion estimate. Case A-3 is deliberately less favorable for LBFS and should later be added as a model-error stress case, not hidden.

### B02. Dai-Huo multiscale priority model (P12/P13)

P12 v2 PDF pp12-15, equation (4.13), Tables 2-4. Five-stage route 1->2->3->4->5->exit; stations {1,3,5}, {2,4}; highest-first priorities `(5,3,1)` and `(2,4)`. Arrival mean=1, gamma shape=0.75. Service gamma shapes by stage=(0.95,0.6,0.95,0.6,0.95); scale=mean/shape (not rate). Means: `(m1,m3,m5)=rho1*(1/2,1/4,1/4)`, `(m2,m4)=rho2*(1/3,2/3)`, rho2=0.99. Set c_e^2=1/0.75 and c_sk^2=1/shape_k.

For this policy define `a=m1+m3-m5*m2/m4`. The formula printed on p13 is

```text
d1 = [a^2*c_e^2 + m1^2*c_s1^2 + m3^2*c_s3^2 + m5^2*c_s5^2
      + (m5/m4)^2*(m2^2*c_s2^2+m4^2*c_s4^2)]/(2*a)
d4 = [(m2+m4)^2*c_e^2+m2^2*c_s2^2+m4^2*c_s4^2]/(2*m4)
E[Q1] approximately d1/(1-rho1); E[Q4] approximately d4/(1-rho2).
```

| rho1 | Formula E[Q1], independently evaluated | Printed M-Scale Q1 | Printed simulated Q1 | Formula / printed M-Scale Q4 | Printed simulated Q4 |
|---|---|---|---|---|---|
| 0.90 | 7.529605263157895 | 7.53 | 7.17 +/-0.02 | 167.75 | 163.23 +/-4.48 |
| 0.96 | 20.07894736842105 | 20.08 | 19.71 +/-0.11 | 167.75 | 166.52 +/-4.25 |
| 0.99 | 82.82565789473684 | 82.83 | 82.80 +/-2.04 | 167.75 | 159.44 +/-3.12 |

At rho1=0.96, mean total cycletime from the low-priority approximation is 187.828947..., printed 187.828, while Table 4 simulation is 185.250 +/-0.001 for this policy. The paper's table is not a consistent nearest-rounding oracle for every last digit; test the displayed formulas numerically and retain the printed value as provenance. High-priority queues are omitted from this leading-order approximation, not set to zero in the actual network. Before supporting other policies use the general theorem mapping, not the above special formula with reordered labels.

### B03. Occupation-measure BAR LP (P24)

PDF p15/Table 1 uses E07, n=100 grid and polynomial degree m=3,...,10. Published E[Z1] is 0.5 throughout; selected E[Z2] estimates are m=3:0.793, m=6:0.768, m=10:0.750. Exact mean is 0.75. These give reproduction milestones but not a guarantee of monotone error with m. PDF p17/Table 3 uses E06 and exact means (0.5,2); m=10 reports (0.5002,1.9996). Preserve the paper's grid definition (14) and objective/normalization to reproduce its discrete LP; a different adaptive grid should be judged against the exact values, not exact equality to its LP numbers.

### B04. Priority OU paper comparison (P24/P38)

P24 PDF pp25-27, section 6.4/Table 5, kappa=(0.5,0.5), gamma=(0.25,0.25). Printed first-coordinate raw moments are (-0.25,0.56,-0.39,0.94), consistent with the exact E10 values after rounding. Second-coordinate historical simulation moments are (1.19,8.31,70.67,854); unsmoothed LP=(1.26,7.79,69.68,812), smoothed LP=(1.16,7.44,66.88,771). The draft calls the simulated column 'true value'; Qnet must not.

The numerical paragraph does not fully restate the service-rate choice or simulation uncertainty. Therefore **do not use its X2 numbers as a fully specified golden test until mu1/mu2 and simulation details are reconciled with P38 or the author implementation**. E10 deliberately supplies mu1=mu2=1 and has an exact X1 oracle now; obtain its X2 reference independently. This explicit hold prevents accidental false validation against an under-specified example.

### B05. Colledani-Gershwin manufacturing line (P35)

PDF pp15-16, Tables 1-2, case 1. Five continuous-material machines; up->down rates p=(0.0125,0.005,0.02,0.01,0.01), down->up rates r=(0.2,0.05,0.2,0.1,0.08); processing rates=(1.111,1.667,1,1.428,1.25); four buffer capacities=(15,20,10,15). Each two-state machine generator is `[[-p,p],[r,-r]]` in (up,down) order, rate vector=(mu,0). **Boundary convention:** section 2, PDF pp4-5, uses operation-dependent transitions. A positive-rate machine slowed by blocking/starvation changes its outgoing state-transition rates by actual-production-rate / nominal-production-rate (equation (1)); a completely stopped up machine therefore stops its operating failure clock. A down state is not classified as starved/blocked by those definitions, so its repair transition remains active. The first machine is never externally starved and the last is never externally blocked. Do not reproduce this benchmark with independent calendar-time failures at the boundaries.

Published CG outputs: production rate=**0.85809**, mean buffer levels=(**11.946,18.618,1.1042,2.4878**). Historical simulation outputs=(0.857; 12.1859,18.6721,1.1896,2.6398). These are different model/numerical estimates, not interchangeable exact values. Proposed initial paper-reproduction gate: throughput within 0.5% of CG and each mean buffer level within 0.5% of its capacity of CG; then tighten based on the actual implemented decomposition. Report buffer discrepancy both in units and as fraction of capacity: the paper's inventory error denominator is capacity, not the mean level. Retain rounded machine rates as printed; do not silently replace 1.111 with 10/9.

### B06. Dai-Zhang neural results (P16)

PDF pp8-12: the target demonstrated is `P(sum_j Z_j>t)`, with 2D E07 and 20D/30D E08. Figure 2 compares tails down to approximately 1%; it is not evidence for ultra-rare-event accuracy. Appendix B Tables 1-3 test raw coordinate moments. The **true** moment columns are exactly generated by E08, so use factorial/rate formulas rather than rounded table digits.

Keep a diagnostic fixture recording that Table 3 (PDF pp15-16), zero-based coordinate 12, reports true second moment about 0.0118 and neural prediction -0.00212. This is not a target to emulate: a result validator must reject that prediction for a nonnegative variable. Paper reproduction and acceptable Qnet behavior are separate objectives. See A29 for architecture, training parameters, scope limitations and release gates.

### B07. Additional paper-specific output requirements

| Paper / location | Output that its future implementation must expose | Oracle or extraction gate |
|---|---|---|
| P14 eqs (3.9)-(3.13), PDF pp6-7 | Effective hitting probabilities w, variance terms, exponential scales, approximate means/tails | Formula unit tests and A03 independent-station reduction |
| P21 eqs (5)-(14), PDF pp3-5 | Kernel roots/branch choices, boundary transforms, normalized interior transform | E06/E07/E08; equation residual and independent density integration |
| P29 sections 2-4 | Normalizers for population/multiplicity states, throughput ratios, mean occupancies | E09 and independent enumeration; not a BAR-moment SDP |
| P43 eqs (2)-(9), Algorithm 1, PDF pp3-5 | Minimal nonnegative return matrices Psi and Psi-hat, residual/convergence history | E11 exact values plus noncommuting multi-phase cases |
| P03 closed QNET formulation/contents, PDF pp1-3 onward | Throughput/cycle time, constrained workload and population mapping | E13 geometry and a fully transcribed paper model before queue-level reproduction |
| P26/P28 truncation theory | Retained stationary law, tail/moment constraints, legitimate bounds if available | E01/E03 plus a non-product-form PH case; not just small cap mass |
| P31/P39/P44 Poisson/Lyapunov methods | Expectation estimates/bounds, test functions, residuals and variance evidence | E04/E14, martingale/dual sign identities |

## 6. Algorithm work packages A01-A32

Each card specifies a future owner, file scope, build profile, implementation sequence, outputs and acceptance. Proposed directories do not yet exist unless explicitly identified as extensions. `Depends` means the listed interface/oracle must be available, not that the whole other research program must be complete. Effort: M=moderate bounded extension, H=substantial model/numerical work, R=research with uncertain feasibility. These are relative estimates, not delivery promises.

### A01. PH/MAP model compilers and matrix-analytic acceleration

**Owner:** matrix-model agent. **Scope:** extend `infinite/matrix_analytic/` with `ph.py`, `map.py`, `model_compiler.py`, `reduction.py`, tests/examples; F00 owns shared schemas. **Build:** D0 oracle, D1 acceleration. **Depends:** F00, E01/E02. **Effort:** H. **Sources:** P43, P47, P54 primary record; current QBD README.

1. Validate PH `(alpha,T)` using nonnegative initial probabilities, transient subgenerator, exit vector `t=-T*1`, proper absorption and finite moments. Compute moment k by `k!*alpha*(-T)^(-k)*1` using solves. Handle atoms at zero only through an explicit extension.
2. Validate MAP `(D0,D1)`: D1>=0, D0 substochastic generator, D=D0+D1 irreducible generator; solve eta*D=0, eta*1=1; arrival rate=eta*D1*1. Keep arrival-epoch and arbitrary-time phase distributions distinct.
3. First compile MAP/PH/1. With interior phases (arrival phase, service phase), use `Aup=D1 kron I`, `Asame=D0 kron I+I kron T`, `Adown=I kron (t*alpha)`. Boundary has arrival phases only: B00=D0, B01=D1 kron alpha, B10=I kron t, B11=Asame. Validate row sums independently before calling QBD.
4. Add cyclic/logarithmic reduction or invariant-subspace method with minimal-nonnegative solution checks; retain existing functional iteration as a small-case comparator. Preserve noncommuting matrix order. A general network compiler is a later finite/truncated phase CTMC, not an automatic infinite QBD.
5. PH fitting is optional: fit trace/distribution by P47 EM or explicit Erlang/hyperexponential construction; output fit diagnostics and separate model-fitting error. Never claim a two-moment PH fit preserves tails.

**Outputs/tests:** phase-resolved stationary masses, queue-level PMF/tails/moments, throughput, Rq, drift, residuals, phase count and condition estimates; PH mean/SCV and MAP intensity. E01/E02 T0, an MMPP two-phase case versus independently assembled truncation, near-critical convergence, wrong-size/nontransient PH, reducible MAP, and memory-cap tests. Accept only after level/customer mapping is demonstrated. **Tradeoff:** richer distributional input, but phase explosion and fitting bias.

### A02. Non-product-form CTMC truncation with defensible error bounds

**Owner:** truncation agent. **Scope:** extend `infinite/truncated_ctmc/` with sparse state builder, boundary policies and certificate records; reuse `finite/generic_ctmc` event definitions. **Build:** D1, D3 optional bounds. **Depends:** F00/A01 phase schema. **Effort:** H. **Sources:** P26/P28.

1. Separate true-chain generator callbacks from the finite approximation. State includes counts, phases and policy state sufficient for Markovianity. Start with a two-node PH tandem; use total population plus phase count caps and deterministic state indexing.
2. Enumerate reachable states, report all cut transitions, and implement separately named augmentation/reflection policies. Suppressing arrivals changes the process; report the approximate chain actually solved.
3. Construct sparse Q_T and solve stationary balance with normalization; report cut-rate reward and state mass, but never label them total-variation error without a theorem.
4. Implement a first rigorous bound only for an explicitly proved subclass: choose a norm-like V, establish a Foster drift inequality globally outside a finite set, bound stationary V, and use the corresponding mass/moment constraints in the P26 truncation LP. Balance equations must account for unknown outside inflow; enforce exact truncated equations only on states whose required predecessors are all included. Store the proof assumptions and truncation geometry.
5. If no usable Lyapunov bound is available, still return a labeled numerical approximation/refinement history. Add non-product-form certificates only after proving the relevant inequality; do not transfer the Jackson certificate unchanged.

**Outputs/tests:** retained PMF, supported moments/tails, discarded transition ledger, refinement deltas, proven mass/moment bounds when available, and explicit lack of retained-state bias certificate otherwise. E01 tail mass beyond cap K is `(2/3)^(K+1)`; E03 untruncated finite chain must meet T0. PH tandem compared with DES/QBD where representable; cap monotonicity is tested only for metrics/policies with a monotonicity theorem. **Tradeoff:** excellent reference computation, combinatorial states and potentially loose certificates.

### A03. Direct GJN multiscale BAR approximation

**Owner:** queue-BAR mapping agent. **Scope:** proposed `infinite/gjn_multiscale/`; do not rename existing SBD or SRBM multiscale code. **Build:** D0/D1. **Depends:** F00. **Effort:** M-H. **Source:** P14 v3, eqs (3.9)-(3.13), assumptions 3.1-3.3.

1. Admit single-class, single-server open GJN with independent renewal external streams, independent service sequences and Markov routing. Solve `lambda=alpha+P^T*lambda` in column-vector notation. Record load and primitive-moment assumptions separately from numerical stability.
2. Order stations by increasing heavy-traffic normalization factor `(1-rho)^(-1)`; preserve permutation. Ties/weak separation are a warning about the approximation, not evidence of the asymptotic regime. Allow user-specified asymptotic order for theorem-oriented experiments.
3. Compute column j of w with linear solves: `w[1:j-1,j]=(I-P_<j)^(-1)*P_<j,j`; `w[j:J,j]=P_[j:J],j+P_[j:J],<j*w[1:j-1,j]`. Check 0<=w<=1 and hitting-probability interpretation.
4. Compute `sigma_j^2=sum_(i<j) alpha_i*(w_ij^2*c_ei^2+w_ij*(1-w_ij)) + alpha_j*c_ej^2 + sum_(i>j) lambda_i*(w_ij^2*c_si^2+w_ij*(1-w_ij)) + lambda_j*(c_sj^2*(1-w_jj)^2+w_jj*(1-w_jj))`; then `d_j=sigma_j^2/(2*lambda_j*(1-w_jj))`.
5. Offer the paper's finite-load mean scale `rho_j*d_j/(1-rho_j)` and a separately labeled asymptotic scaling. Do not silently round continuous exponential coordinates into geometric queues; define any discretization and resulting mean changes explicitly.

**Outputs/tests:** w, component variance terms, d, load order/separation ratios, exponential mean/tail approximations and asymptotic assumptions. Independent Poisson/exponential stations have d=1 and exact M/M/1 means via the finite-load correction, but exponential tails are not exact geometric tails. Zero-arrival/inactive stations need explicit reduction to avoid division by zero. Routing permutation and feedback-hitting tests; compare load-separated two/three-node models against DES. **Tradeoff:** cheap scalable estimates, no finite-load error guarantee or recovered dependence.

### A04. Higher-order stationary diffusion corrections

**Owner:** generator-approximation research agent. **Scope:** proposed `infinite/high_order_diffusion/`. **Build:** D1/D2. **Depends:** F00, exact birth-death oracle. **Effort:** R. **Source:** P17 v4, section 1 density (3), section 3 Erlang-C construction.

1. Start with the paper's Erlang-C model, not an arbitrary GJN. Center/scale its count state; derive drift and conditional jump moments directly from the birth/death generator. Store the derivation and units.
2. Implement constant-variance v0 and state-dependent v1 as separate baselines. The scalar stationary density is proportional to `exp(integral b/v)/v`, where diffusion covariance is **2v**. Enforce v>0 and normalizability on the stated support; treat piecewise drift at the server threshold exactly.
3. Implement the paper's higher-order Stein/Poisson recursion only after verifying its scalar coefficient formulas. Do not replace a third-order Kramers-Moyal truncation with a purported positive diffusion generator. If a correction makes v nonpositive, stop with an unsupported/invalid approximation outcome, not arbitrary clipping.
4. Map centered continuous density to queue observables with a declared continuity correction; independently measure error against exact M/M/n recursion. Test offered loads and server counts across ordinary and heavy traffic.

**Outputs/tests:** density/CDF, mean queue and wait probability, v0/v1/higher-order results side by side, positivity/tail diagnostics and queue-model discrepancies. Scalar OU and E04 reductions verify density normalization; Erlang-C comparisons establish whether improved order is observed in the studied scaling. No required improvement at every finite parameter point. A multidimensional extension is a distinct research milestone with its own derivation and covariance-PSD checks. **Tradeoff:** potentially improves model accuracy, but established constructions are model-specific.

### A05. Tensor-train stationary CTMC solution

**Owner:** structured-linear-algebra research agent. **Scope:** proposed `infinite/tensor_ctmc/`; reuse generator semantics from A02/A06. **Build:** D1, optional separately licensed tensor library only after review. **Depends:** F00, exact finite generators. **Effort:** R. **Source:** P30.

1. Construct Q as a sum of Kronecker local-event operators with explicit buffer dimensions. A routed event touches two stations; a priority/blocked event may touch more. Verify the tensor operator against a dense materialization on tiny models.
2. Solve `Q^T*p=0`, `1^T*p=1` by alternating local core solves with normalization constraint, rank adaptation and residual-controlled truncation. Retain a full sparse solver for small cases.
3. Track tensor rank, true unpreconditioned residual, normalization, marginal negativity, and matvec cost. Small residual alone is not a stationary-distribution error bound without conditioning/gap information. Tensor truncation does not automatically preserve positivity.
4. Start with independent finite queues (exact rank one), then a small finite tandem and a reliability-modulated line. No assertion of polynomial scaling for arbitrary routing/strong coupling.

**Outputs/tests:** compressed PMF representation with dimension ordering, exact-to-tolerance contractions for selected marginals/rewards, residual and rank history, negativity diagnostics, optional explicit small PMF. E03 two independent copies must recover rank-one law and T0 statistics. Coupled test must match sparse stationary solution; demonstrate both a compressible and a rank-exploding case with graceful resource stop. **Tradeoff:** large storage savings when structure permits, potentially high ranks/conditioning otherwise.

### A06. Exact finite two-machine and small-line building blocks

**Owner:** manufacturing Markov-model agent. **Scope:** proposed `finite/transfer_line_exact/`, with adapters to `finite/generic_ctmc/`. **Build:** D0 tiny enumerator, D1 sparse. **Depends:** F00, E12. **Effort:** H. **Sources:** P34/P35 model definitions; P48/P53 for blocking taxonomy when obtained.

1. Implement E12 first using named machine states, not merely buffer occupancies. Extend to intermediate capacity B=0,1,2, service phases, machine up/down states and specified BAS transfer events.
2. Define simultaneous transfer as an atomic state transition when downstream capacity is released. Construct the reachable graph from a declared initial state; aggregate duplicate event rates and set diagonal to negative total off-diagonal rate. Include blocked completed jobs in system population.
3. Separate lost-on-full, BAS, and blocking-before-service model types. For failure during service specify resume/restart, whether work survives, and whether the failure clock stops while idle/blocked. Reject absent semantics rather than choose silently.
4. Solve finite stationary Q and reward equations; detect reducibility/deadlock. For continuous-material building blocks call A08 instead of treating fractional inventory as a job count.

**Outputs/tests:** throughput, full PMF for small cases, mean inventory/WIP, starvation/processing/blocked/down fractions per machine, buffer full/empty probabilities and flow balance. E12 T0; independent direct enumeration for capacities 1/2; no-failure limit; one-machine reduction; parameter permutation with reversed line only where the symmetry actually holds. Compare sampled event trajectories against the specified transitions before long DES validation. **Tradeoff:** exact and excellent as a decomposition/reference block, but not scalable to long phase-rich lines.

### A07. Blocking-aware transfer-line decomposition

**Owner:** manufacturing decomposition agent. **Scope:** proposed `finite/transfer_line_decomp/`; distinguish from existing general `fBNAdecomp`. **Build:** D1, A08 fluid block. **Depends:** F00/A06 or A08 depending on model. **Effort:** H. **Sources:** P34; P35 sections 4-7 and B05.

1. Implement the P35 continuous-material model first. Represent each adjacent-buffer subsystem by upstream/downstream pseudo-machines retaining machine states and processing rates, including partial starvation/blocking states.
2. Transcribe the chosen paper's pseudo-machine transition closures into a derivation document before coding. Do not mix Burman's closures with Colledani-Gershwin's and label the result a reproduction. Build local balance/flow tests for each closure. B05 needs operation-dependent transition rates at empty/full boundaries, so the A08 block must support boundary-specific phase generators, not only its constant-generator P43 baseline.
3. Iterate subsystem solutions with documented initialization and damping. Match common throughput and the required neighboring flow/interruption quantities; stop on both parameter-change and flow residual. Detect cycling/nonphysical rates. Optional acceleration must leave the fixed point unchanged.
4. Add multi-down-state repair and parallel-machine stages after the two-state case. For k independent identical up/down machines, environment transitions j->j-1 at j*p, j->j+1 at (k-j)*r, production j*mu; test this aggregate chain independently.

**Outputs/tests:** line throughput, per-buffer mean/full/empty/inventory distributions when the local block supplies them, station environment and blocking/starvation estimates, iteration history and residual. B05 is the paper comparison; two machines must reduce to the block solver, not another approximation. Run 3/5/10-machine simulation comparisons with identical continuous/discrete semantics; preserve errors as model evidence, not numerical tolerance. **Tradeoff:** useful industrial scaling, approximate cross-buffer dependence and possible difficult fixed points.

### A08. Markov-modulated fluid queues and doubling

**Owner:** fluid-queue agent. **Scope:** proposed `finite/markov_fluid/` with shared infinite-storage mode. **Build:** D1/D2. **Depends:** F00/E11. **Effort:** H. **Source:** P43 eqs (2)-(9), Algorithm 1; P35 for finite storage.

1. Partition phase generator T by positive/negative fluid velocities and diagonal C. Handle zero-rate states by justified censoring/recovery, or reject them in milestone 1; reliability models often need them, so do not forget their restoration.
2. Solve the Riccati equation `Cplus^-1*Tpm + Psi*abs(Cminus)^-1*Tmm + Cplus^-1*Tpp*Psi + Psi*abs(Cminus)^-1*Tmp*Psi=0` for its minimal nonnegative solution. Implement paper initialization with admissible alpha/beta, using linear solves instead of explicit inverses.
3. Doubling step: `Enew=E*(I-GH)^-1*E`, `Fnew=F*(I-HG)^-1*F`, `Gnew=G+E*(I-GH)^-1*G*F`, `Hnew=H+F*(I-HG)^-1*H*E`. Compute all new blocks from the old iteration, not sequentially overwritten blocks. G/H converge to the return matrices.
4. Reconstruct stationary phase densities and boundary atoms using the appropriate fluid balance equations. Finite K needs **both endpoints** and its own normalization/flux solve; return probabilities alone are not a stationary solution. To supply P35 manufacturing blocks, add separate phase-transition generators at 0 and K implementing operation-dependent slowing, plus zero-rate-state recovery. Validate those boundary generators before using A08 inside A07; the constant-generator infinite-fluid theorem is not that complete boundary model.

**Outputs/tests:** Psi/Psi-hat, Riccati residuals, phase-resolved density and atoms, moments/tails, overflow/starvation reward rates. E11 Psi=1, Psi-hat=0.5 and atom=1/3; independent finite-difference fluid CTMC at shrinking step; unequal positive/negative phase counts to detect transpose errors. Stable infinite mode requires negative stationary average fluid drift; bounded mode has different recurrence conditions. **Tradeoff:** exact within the fluid model, not the original discrete production line.

### A09. Complete bounded-domain BAR solver

**Owner:** bounded-diffusion agent. **Scope:** extend `finite/fBNAlp/` only after examining its documented scaffold, or build isolated Python reference `finite/bounded_bar/` first. **Build:** D1/D3 reference, D5 optional native. **Depends:** F00/E05/E13. **Effort:** H. **Sources:** P01/P05/P06/P24.

1. Implement box generator and all 2d face measures. Interior weights sum to one; face weights are nonnegative unnormalized rates. For polynomial/compact test functions construct interior Lf and directional derivatives on each actual face.
2. Solve a normalized nonnegative occupation LP or weak FEM system. Record whether unknowns are point masses, cell masses, density coefficients or boundary local-time weights; include quadrature/cell volume consistently.
3. Validate upper-face sign and `exp(-s_i*K_i)` in independent transform tests. Corners must not be double-counted as interior mass or assigned fictitious face probability atoms.
4. Add adaptive local refinement near boundary layers; constrain no-flux only in the mathematically correct oblique weak formulation. Separate a finite queue mapping from a numerical box supplied directly by the user.

**Outputs/tests:** stationary density/cell mass, coordinate and cross moments, marginal CDFs, all face rates, linear/quadratic BAR residuals and refinement history. E05 and its unequal-coordinate product box; E13 after simplex support is explicitly added. Compare P05 paper cases only after matching normalization and reflection layouts. P06's block-and-hold-0 limit is a specific queue mapping, not authorization to call every BAS box exact. **Tradeoff:** closes an important finite-domain gap, spatial dimension remains expensive.

### A10. Exact MVA and convolution for closed networks

**Owner:** closed-network agent. **Scope:** extend `infinite/product_form/` with `mva.py`, `convolution.py`, algorithm selection and tests; keep existing enumeration. **Build:** D0, optional D1. **Depends:** F00/E09. **Effort:** M-H. **Sources:** P51 primary record, current BCMP factors, P29 background.

1. Start with load-independent single-server BCMP centers and delay centers. For population vector N and active class r, evaluate the smaller population N-e_r first. Per-visit residence at a single-server center is `T_ir(N)=S_ir*(1+sum_s Q_is(N-e_r))`; for delay centers `T_ir=S_ir`.
2. Class reference throughput is `X_r=N_r/sum_i V_ir*T_ir`; update `Q_ir=X_r*V_ir*T_ir`. Set zero-population class results explicitly. Cache population states in a dependency-safe order and estimate their count `product_r(N_r+1)` before allocation.
3. Implement convolution of local product-form factors, in scaled/log-safe arithmetic, to obtain G and requested marginal normalizers. Single-class recursion `G_m(n)=sum_(k=0..n) f_m(k)*G_(m-1)(n-k)` is the first reference. Extend to multiclass vectors with storage control.
4. Multi-server FCFS requires occupancy-probability/extended MVA or convolution of the actual `product min(k,c)` factors; elementary MVA above must refuse it. Maintain the existing discipline-specific BCMP assumptions and visit/reference scaling.

**Outputs/tests:** exact-to-numerics throughputs, mean occupancies/residences/utilizations; G and marginals only from algorithms that compute them; storage estimate and selected method. E09 both single/multiclass T0, N=0, delay-only, visit-vector rescaling and existing enumeration examples. A mean-only MVA run must not advertise a full joint PMF. **Tradeoff:** high practical value, exponential population-vector growth with class count still matters.

### A11. Multi-branched Method of Moments / normalizer recursions

**Owner:** closed-normalizer specialist. **Scope:** `infinite/product_form/mom.py` plus isolated recurrence/basis tests. **Build:** D0 rational oracle; D1/D2 optional. **Depends:** A10 exact normalizers/E09. **Effort:** H. **Source:** P29 sections 2-4; missing full RECAL reference must be acquired before a separately named RECAL implementation.

1. Implement the paper's convolution and population constraints over multiplicity/population-indexed normalizers. Construct the initial basis exactly for the two-center/two-class motivating example; unit-test each row by substituting independently enumerated G values.
2. Build the matrix difference system and the multi-branched basis reduction, retaining deterministic index maps. Use exact rational arithmetic for small integer/rational demands to expose coefficient or normalization errors.
3. Add scaled/high-precision linear solves and conditioning checks for larger cases. A singular recurrence must select a documented alternative basis/fallback, not return a pseudoinverse result as exact without justification.
4. Obtain throughput `G(m,N-e_r)/G(m,N)` and occupancy via the appropriate augmented-center normalizer ratio. Test station multiplicities separately; an added identical center is not an added server at the same FCFS queue.

**Outputs/tests:** normalizers/ratios, throughput/mean occupancy, basis size, arithmetic precision, linear residual and conditioning. E09, a three-class model versus convolution, repeated-center equivalence and zero demands. Benchmarks compare operation counts/memory as well as accuracy; no universal speed superiority is assumed. **Tradeoff:** can avoid large population enumeration, at the cost of intricate recurrences and numerical conditioning.

### A12. Approximate MVA and Linearizer track

**Owner:** closed-approximation agent. **Scope:** `infinite/product_form/amva.py` or separately labeled approximate module; no change to exact claim labels. **Build:** D0/D1. **Depends:** A10. **Effort:** M-H. **Sources:** P51 and Chandy-Neuse 1982 primary record.

1. Implement a named initial AMVA closure: in the arrival-theorem expression approximate removal of class r by scaling only its occupancy contribution `Q_ir*(N_r-1)/N_r`, leaving other class contributions unchanged. Zero populations are excluded. Use fixed-point initialization and damping explicitly; output convergence history.
2. Test this on exactly the single-server/delay BCMP class admitted by A10; do not initially add arbitrary-service FCFS, priority or blocking corrections.
3. Add Linearizer only after obtaining the full Chandy-Neuse algorithm and recording its reduced-population auxiliary solves/linearization rules. The primary abstract does not supply that algorithm. Do not label the preceding closure 'Linearizer'.
4. Compare low populations and strongly unbalanced class demands against exact MVA; include cases where the approximation is poor. Stop on resource/iteration limits with partial status and retained residual.

**Outputs/tests:** approximate throughput/occupancies/residence, population and Little's-law identities, iteration counts, method-specific closure label and exact-comparator errors. E09, N=1 reduction, equal-class symmetry, heavy-population sweeps. Proposed performance gate is no catastrophic population/flow violation, not an invented universal percentage error. Publish a measured error envelope over the benchmark grid before making it a recommended automatic fallback. **Tradeoff:** inexpensive scale, no exact-law or convergence-to-truth guarantee.

### A13. Closed-network Brownian QNET on a simplex

**Owner:** closed-diffusion research agent. **Scope:** proposed `infinite/closed_brownian/`, using A09 geometry/numerics. **Build:** D1/D2, D5 optional. **Depends:** F00/A09/E13 and closed DES. **Effort:** H-R. **Source:** P03, closed manufacturing model and simplex reduction.

1. Transcribe one complete P03 model, with class/station service assumptions and fixed population, into a versioned fixture. Its common service-time law across classes at a station is part of the first admission contract. The opening scanned pages alone are insufficient for the mapping; read the reduction/parameter-construction sections in full.
2. Derive the conserved population constraint, workload coordinates, drift/covariance and reflection in reduced independent coordinates. Store both reduction and inverse observable map. Avoid singular 'open network with zero arrivals' export.
3. Solve the reduced compact-domain weak stationary problem; use appropriate simplex mesh/basis and true face directions. Recover throughput and cycle time by the paper's flow mapping, not by treating boundary rates as external arrivals.
4. Implement exact product-form closed examples as queue benchmarks where they meet both model contracts, then non-exponential supported examples versus closed DES.

**Outputs/tests:** constrained workload law/moments, covariance respecting conservation, per-class/station queue approximations where derived, throughput/cycle time and approximation label. E13 geometry T1, sum-of-population identity to arithmetic tolerance, equivalent coordinate eliminations and two exact closed examples. Release hold: no generic GUI admission until a complete paper model and its normalization are independently reproduced. **Tradeoff:** strong alignment with Qnet's Brownian engines, but closed-network geometry and mapping are genuinely new.

### A14. CONWIP, pallets and closed-loop decomposition

**Owner:** closed-manufacturing agent. **Scope:** proposed `finite/closed_loop/`; reuse A06/A07 where semantics match. **Build:** D1. **Depends:** F00/A06/A10, later A07. **Effort:** H. **Source:** P42.

1. Add tokens/pallets as explicit conserved resources with release and return locations; specify whether empty pallets consume buffers/transport time. Separate processing customers from permission tokens when they are not identical.
2. Build tiny closed-loop CTMC/DES references before decomposition. Reachability analysis must detect deadlocks and multiple recurrent classes; return initial-class-dependent results or an explicit refusal.
3. Implement the selected P42 closed-loop decomposition with throughput consistency and token-population equations. Add a scalar outer root solve for the conserved population only after establishing its feasible range and local monotonic behavior.
4. Sweep token population to expose starvation versus blocking; preserve physical caps and machine reliability states. Do not promise throughput increases forever or monotonically under every blocking model.

**Outputs/tests:** throughput versus pallet count, mean WIP and cycle time, token allocation, blocking/starvation, deadlock classification, convergence. E13 one-customer loop, an unblocked product-form cyclic model via A10, and explicit deadlocked zero-space loop under its stated blocking policy. Compare paper examples only after fully transcribing the token convention. **Tradeoff:** directly useful manufacturing planning, stronger state/conservation semantics and approximation complexity.

### A15. FBFS/LBFS priority re-entrant workload-to-RBM mapping

**Owner:** priority-model agent. **Scope:** proposed `infinite/priority_rbm/` with `mapping.py`, `fbfs_refinement.py`, fixtures/tests and an adapter to existing SRBM engines. **Build:** D1; existing native backend optional. **Depends:** F00/E06/E07, priority reference DES. **Effort:** H. **Source:** P04 sections 3-5, eqs (3.1)-(3.5), (4.1)-(4.4), B01.

1. Admit deterministic re-entrant routes, one server/station, preemptive-resume FBFS or LBFS, independent renewal arrivals and independent stage services with finite required moments. Normalize external arrival rate to one by time t'=alpha*t and service means m'=alpha*m; retain the inverse conversion. No arbitrary priority or nonpreemptive theorem is implied.
2. Let C be station/class incidence, M=diag(m'), P the deterministic next-stage matrix, and ell(i) the lowest-priority stage at station i. Set A[ell(i),i]=1/m'_ell(i), all other entries zero. Check C*M*A=I. Compute `H=C*M*(I-P^T)^(-1)*A` by solves, `R=H^(-1)`, and b=`-R*(1-rho)`. This construction, unlike a station-aggregated FCFS exporter, changes with the priority policy.
3. For the independent stage primitives in milestone 1, form `v=C*m'`, `V=C*diag((m'_k)^2*c_sk^2)*C^T+c_e^2*v*v^T` and `Sigma=R*V*R^T`, corresponding to the independent-primitive specialization of the paper's workload covariance. Derive/check this specialization against section 5 before extending to correlated stage times; the general service-process covariance cannot be substituted without its proper scaling.
4. Validate Brownian existence/stationarity for the supported FBFS/LBFS subclass. A backend restricted to M-matrix R might not admit every resulting reflection matrix; report backend capability separately. Do not silently change R to fit it.
5. Basic state-space-collapse mapping is Q_ell(i)=E[Z_i]/m'_ell(i), with high-priority components absent on this scale. Add the paper's **separate recursive FBFS refinement**: solve successively enlarged initial-stage subnetworks, adding at most one unknown stage per station; recover the new mean from workload minus previously assigned workload divided by its service mean. A negative recovered queue is a failure/warning to investigate, not silently clipped.
6. Return workloads in original time units by dividing normalized workloads by alpha; counts are unchanged; mean network sojourn=sum class means/alpha.

**Exact parameter test for B01:** FBFS gives `R=[[1,-0.5],[0,1]]`, b=(-0.05,-0.1), Sigma=diag(0.81,1.62). LBFS gives `R=[[1,-0.5],[-2,2]]`, b=(-0.05,0), `Sigma=[[0.81,-1.62],[-1.62,4.86]]`. Do not normalize R's diagonal without inversely rescaling its regulators; stationary state law is invariant to positive column normalization, reported beta is not.

**Outputs/tests:** full mapping matrices and stage IDs, workload means/law supported by backend, leading and refined class means with distinct labels, network sojourn and backend evidence. Parameter matrices T0, B01 numerical reproduction, one-stage M/G/1 reduction, swapped priority, unit rescaling, unsupported nonpreemptive input, and physically loaded/near-critical examples. Verify simulation uses workload `sum m_k*Q_k`, not residual unfinished work, when comparing the paper's observable. **Tradeoff:** high-value priority coverage, restricted scheduling and asymptotic class mapping.

### A16. Static-buffer-priority multiscale BAR limits

**Owner:** priority-asymptotics agent. **Scope:** proposed `infinite/priority_multiscale/`, shared schemas with A15. **Build:** D0/D1. **Depends:** F00/B02, priority DES. **Effort:** H-R. **Sources:** P11/P12/P13/P15.

1. Implement the fully specified B02 two-station/five-stage case first, using the recorded d1/d4 formulas. Check physical loads and the case-study virtual-station load `alpha*(m2+m5)<1` for the stated `(5,3,1),(2,4)` policy, plus all paper assumptions. The virtual condition belongs to that policy/model, not every SBP network.
2. Compute limiting independent exponential coordinates and finite-load means with explicit scale factors. Report which high-priority coordinates vanish in the limit and leave finite-load high-priority means unavailable unless another approximation estimates them.
3. Add a general SBP compiler using the class partition, service/routing matrices, low/high-priority block elimination, state-space-collapse map and covariance from P11/P12. Unit-test each intermediate block against the two-station construction before extending dimensions.
4. Implement structural checks for proved subclasses of the tight/P-matrix conditions. Do not use numerical stability of a simulated trajectory as a proof of these conditions. Where a general tight-matrix verifier is unavailable, return `assumption_not_verified` and do not promote the model to certified applicability.
5. Policy comparison is fixed-policy performance estimation first; do not claim stationary optimality of a policy simply because its approximation is smallest.

**Outputs/tests:** d scales, exponential transforms/tails, load/separation data, active coordinates, assumption checks, approximate class means/cycletime and unsupported outputs. B02 analytic formula values T0; printed table T3; DES T4 and empirical dependence diagnostics. Test gamma shape-versus-rate errors, alternate priority order, poor scale separation, and virtual-station overload with physical loads below one. **Tradeoff:** very fast limiting distributions, substantial admission mathematics and unquantified finite-load errors.

### A17. Two-class priority OU / piecewise-linear diffusion

**Owner:** full-space diffusion agent. **Scope:** proposed `infinite/priority_ou/`; do not insert an orthant constraint. **Build:** D1/D2, D3 LP optional. **Depends:** F00/E10, numerical reference diffusion simulation. **Effort:** H. **Sources:** P38 and P24 section 6.

1. Implement E10 drift/covariance and stable model validation as a standalone full-space diffusion. Keep mu/kappa/gamma in input, not hidden constants. The interface x1+x2=0 has continuous drift but a derivative change.
2. Build a 2D stationary finite-volume/FEM reference on a expanding rectangle that straddles the interface, with probability-conservative assembly. Artificial outer-boundary treatment and its truncation effect must be reported; require negligible outer-band mass and stable moments under expansion. A17 is not an orthant SRBM, and artificial rectangle faces are not physical queue regulators.
3. Alternative BAR-LP implementation uses interior occupation weights and no physical face measures. Compare smoothness regularization with the unregularized solution; do not infer accuracy just from a smoother plot.
4. Independently simulate the diffusion, checking X1 against its exact OU transition law/marginal, and refine X2 time steps. Add finite-n priority queue simulation only with a precisely matched scheduling/allocation rule and scaling.

**Outputs/tests:** joint/marginal density, centered first-fourth moments where integrable, probability x1+x2>0, selected weighted-sum tails, truncation/refinement evidence and mapped finite-n counts only with labeled approximation. E10 X1 moments and normal CDF T1, continuity at the drift interface, density nonnegativity, b1 mean balance, and joint comparisons to independent simulation. B04 X2 reproduction is held until missing source parameters are resolved. **Tradeoff:** compelling small priority demonstration, many-server-specific interpretation and full-space tail truncation.

### A18. GI/Ph/n+GI many-server diffusion with abandonment

**Owner:** many-server phase-diffusion agent. **Scope:** proposed `infinite/many_server_diffusion/`; optional reuse of existing multiclass numerical kernel only after coordinate verification. **Build:** D1/D2, D5 optional. **Depends:** F00/A01, E14. **Effort:** H-R. **Sources:** P07/P09.

1. Start with exponential patience and Poisson arrivals, then implement the specific PH service representation from P07. Record centered phase populations, queue/idleness relation, PH entry/routing probabilities and drift/covariance at each piecewise regime.
2. Derive every transition contribution from an exact small PH/n+M CTMC to verify covariance, phase conservation and abandonment reward mapping. Limit initial phase count to two or three.
3. Implement the paper's reference-density projection/FEM for the admitted diffusion, including its tail-compatible reference construction. Validate numerical law independently of the queue approximation.
4. General renewal arrivals and general patience require the paper's stated approximations/hazard assumptions. Label constant-hazard-at-zero versus a more detailed hazard approximation separately; do not call either an exact GI patience Markovization. Claims about stationary convergence must cite the applicable theorem and its assumptions.

**Outputs/tests:** diffusion population density/moments, delay probability, mean queue, service and abandonment rates, phase-level quantities and original-scale mapping. E14 exact Erlang-A queue comparison, exponential-PH reduction, lambda->0, theta->0 under subcritical load, overload with positive abandonment, and high-order phase fitting sensitivity. For lambda above capacity and zero abandonment reject a stationary answer. **Tradeoff:** expands large service-system coverage, but distinct from ordinary GJN and sensitive to patience/service approximation.

### A19. N-system fixed-policy performance

**Owner:** skill-based-service model agent. **Scope:** proposed `infinite/n_system/`; share PH/priority schemas where valid. **Build:** D1. **Depends:** F00/A02/A17 or A18 numerical primitives. **Effort:** H-R. **Source:** P08.

1. Encode two customer classes, two server pools, explicit compatibility graph with three edges, service rates by allowed class-pool pair, abandonment and named fixed priorities/routing rules. Supply a source-to-Qnet label mapping; do not rely on a drawing's station numbering.
2. First build an exact capped CTMC for tiny pool sizes and exponential primitives. State must include customer allocation to pools, not just total class counts. Implement dispatch/preemption semantics explicitly and verify every transition.
3. Implement the P08 diffusion mapping only for its stated pool-dependent service-speed assumptions and specified policy. Reject arbitrary class-dependent speeds if they fall outside the result. Solve the stationary **fixed-policy** generator where positive recurrence is established.
4. Policy optimization is deferred. The source's finite-horizon asymptotic control result must not be presented as a theorem proving stationary optimality for Qnet's model.

**Outputs/tests:** class populations, waiting/abandonment, pool utilization and allocation, throughput and stationary cost for a supplied reward. Disconnecting the flexible edge should reduce to independent queues; identical classes/pools should satisfy aggregate symmetry; tiny models match CTMC; matching large models compare with DES. Full scientific release requires one complete source model and policy fixture, not just a functioning generic CTMC. **Tradeoff:** useful skill-based systems, high modeling and policy-specific validation burden.

### A20. Priority polling transforms

**Owner:** polling/transform agent. **Scope:** proposed `infinite/priority_polling/`, invoking A27. **Build:** D1/D2. **Depends:** F00/A27; a small polling DES reference. **Effort:** H. **Source:** P45.

1. Add one cyclic server visiting multiple queues, positive or explicitly zero switchover laws, Poisson class arrivals, service-time LSTs, and the supported gated/exhaustive priority discipline. Identify the precise branching-type subclass treated by the source before admitting it.
2. Implement embedded visit-beginning PGF equations and the branching/substitution transform for each discipline. Solve their composition using a convergence-controlled iteration and record visit-epoch versus arbitrary-time distributions separately.
3. Derive waiting-time LST for each priority class via the paper's service/visit-cycle decomposition, then call A27. Preserve residual service and residual switchover contributions; do not apply an arbitrary-time formula at a polling epoch.
4. For a single queue with zero switchovers, dispatch to its well-defined limiting priority queue formula; do not numerically iterate a degenerate zero-length polling cycle.

**Outputs/tests:** class waiting LST, mean wait, selected waiting CDF/tails, cycle/intervisit means and epoch-labeled queue statistics. Single-class one-queue M/G/1 reduction using E02 waiting LST, identical symmetric queues, service/switchover deterministic-versus-PH comparison and independent DES. Test nonpreemptive/preemptive distinctions and refusal of unsupported mixed service discipline. **Tradeoff:** valuable specialized shared-server networks, not a general multi-server GJN method.

### A21. Exact RBM structure detection and special distributions

**Owner:** exact-diffusion agent. **Scope:** extend `infinite/bar_bounds/` exact utilities or proposed `common/qnet_diffusions/exact.py`; avoid duplicate skew-symmetry tests with inconsistent tolerances. **Build:** D0/D1/D2. **Depends:** F00/E04/E06/E08. **Effort:** M-H. **Sources:** P19/P20/P22/P23.

1. Implement exact rational skew testing for supplied decimal/rational primitives where feasible, alongside a separately labeled approximate residual. Check `2*Sigma=R*diag(R)^(-1)*diag(Sigma)+diag(Sigma)*diag(R)^(-1)*R^T`. Compute rate vector `a=-2*diag(Sigma)^(-1)*diag(R)*R^(-1)*b` and require positive rates/admitted stable R.
2. Return exact product transform, independent exponential moments and unnormalized boundary transforms with beta=-R^-1*b. Close-but-not-exact parameters must not inherit the exact label.
3. Add block decomposability tests from P20 with an explicit algebraic witness. Block-diagonal primitives are the first sufficient-condition fixture; general stationary block independence is not inferred merely from small correlations.
4. Add one finite sum-of-exponentials case from P23 and selected P22 special transforms only after transcribing their reflection-angle conditions and coefficients. Signed coefficients can occur in an exact representation; establish nonnegative overall density rather than assuming each coefficient is a mixture weight.

**Outputs/tests:** structural witness, law/transform, moments/cross moments/tails, face rates and exact-versus-numerical claim. E04/E06/E08 T0, deliberately perturbed skew relation, nonsymmetric R, positive column rescaling, block permutation and independent normalization integration. Any exponential-sum benchmark needs its own fully specified local fixture before it becomes a release test. **Tradeoff:** fast exact shortcuts and excellent oracles, narrow admissible structures.

### A22. Adaptive reference-density spectral/Galerkin solver

**Owner:** spectral-numerics agent. **Scope:** extend `infinite/BNAsm/` or isolated reference layer; integration owner selects the maintained engine after interface inspection. **Build:** D1/D2 reference, D5 native. **Depends:** F00/A21 and exact fixtures. **Effort:** H. **Sources:** P02/P07/P24.

1. Express stationary density relative to a positive integrable reference. Choose scales from exact structural solutions or an explicitly approximate mean model; verify the tail conditions required by the selected projection theory rather than choosing a reference solely for visual fit.
2. Assemble weak BAR/Galerkin equations with properly represented face terms and normalization. Cache quadrature/basis derivatives, scale columns, and use stable linear solves.
3. Add nested basis adaptation driven by independent residual, moment change, conditioning and tail mass. Use anisotropic enrichment rather than increasing every dimension's degree blindly. Keep existing fixed-order engine as a comparator.
4. Density negativity must be reported. A positive representation or constrained solve is a separate variant with separate approximation behavior; clipping and renormalization invalidate the original residual calculation unless recomputed and disclosed.

**Outputs/tests:** density/reference ratio coefficients, means/covariance, marginals, boundary-rate estimates, basis/condition/refinement history and failure reason. E04/E06/E07 T1; E08 low dimension; wrong reference-tail stress case; coordinate rescaling and a near-critical case. Compare both spatial and transform residuals at points not used in assembly. **Tradeoff:** reuses existing strengths, basis growth and ill-conditioning remain central risks.

### A23. Adaptive occupation-measure BAR LP

**Owner:** BAR-LP agent. **Scope:** proposed shared `infinite/occupation_bar/` supporting a bounded-domain first milestone, later orthant truncation and full-space OU. **Build:** D1/D3 or HiGHS for pure LP. **Depends:** F00/A09; E05/E07. **Effort:** H. **Source:** P24 sections 2-4, B03; optional full text P50 for comparisons.

1. Represent interior occupation by nonnegative grid masses p and each physical face by nonnegative regulator masses q_i. For test f_j create the row `sum_x p_x*Lf_j(x)+sum_i,y q_iy*D_i f_j(y)=0`, plus sum p=1. On orthant models also enforce known beta through valid linear BAR identities.
2. Reproduce P24's exact grid/test family/objective for a clearly named paper mode. For a new adaptive mode, document the objective and use scaled feasibility tolerances; different optimal feasible distributions may share the same low-order constraints.
3. Refine where independent BAR residual/test-function violations or requested CDF variability are large. Add independent validation functions rather than reusing all training constraints. On unbounded domains add justified tail constraints or explicitly label truncation bias unknown.
4. Optional smoothness/entropy regularization selects a point estimate; it does not create a certified bound. To bound a metric, solve the correct extremal problem over a theorem-backed outer feasible set, not the finite-grid feasible set alone.

**Outputs/tests:** selected occupation law, face measures, moments/CDFs, LP primal/dual status, scaled residuals, refinement/regularization history. E05/E06/E07 and B03; full-space E10 must have no physical faces; upper-face and face-mass tests. Show at least one underdetermined low-order grid example with differing laws to prevent a uniqueness overclaim. **Tradeoff:** flexible and nonnegative, sparse point laws and truncation/admissibility issues.

### A24. Stronger moment LP/SDP bounds

**Owner:** moment-optimization agent. **Scope:** extend `infinite/bar_bounds/`; add box/simplex support only with F00 domain contract. **Build:** D3 plus D0 rational checks. **Depends:** F00/A09/A21. **Effort:** H. **Sources:** P27, P50 accessible record, P19; existing BAR-bound README.

1. Generate monomial multi-indices and independent interior/face moment sequences. For f=x^a, use drift coefficient a_j*b_j and diffusion coefficient `0.5*Sigma_jk*a_j*(a_k-delta_jk)` at the correctly reduced exponent. Generate face derivatives before restricting to the face; some terms survive even when f itself vanishes there.
2. Add BAR equalities, m0=1, face-mass identities and moment/localizing PSD matrices. Orthant constraints are Stieltjes; a box also uses K_i-x_i; a simplex uses remaining population. Enforce face support exactly (x_i=0 or K_i), not merely with sampled penalties.
3. Minimize/maximize each requested moment/cost, increasing degree only with a state/cone-memory estimate. Nonexisting or unproved moments must not be assumed just to close the hierarchy.
4. Report floating-point conic candidates with residuals/minimum eigenvalues. Integrate A25's independent verifier before using `certified=true`; nested theoretical relaxations need not give perfectly monotone floating outputs when solvers are inaccurate.

**Outputs/tests:** lower/upper candidates, moment existence assumptions, relaxation order, cone sizes, primal/dual feasibility diagnostics, any verified certificate. E04/E05/E06 exact moments lie in valid intervals; E07 covariance/moments test coupled face terms; scale/permutation and intentionally infeasible moment sequences. Test a synthetic negative second moment is rejected. P27 is a CTMC moment-bounding source; an RBM extension requires its own face/integrability derivation, not a transferred theorem label. **Tradeoff:** informative intervals, expensive degree growth and difficult numerical certification.

### A25. Dual BAR/Poisson certificates for selected metrics

**Owner:** proof-verification agent. **Scope:** proposed `infinite/bar_certificates/`, separate candidate search and verification modules. **Build:** D3 candidates; D0 rational checks/D2 interval-capable arithmetic chosen and tested separately. **Depends:** F00/E04/A24 candidate interface. **Effort:** H-R. **Sources:** P39/P40 and derivation below.

For g and an admissible h, the sufficient upper-bound conditions are `g+Lh<=U` everywhere in the domain and `D_i h<=0` on every physical face. BAR gives `pi(g)<=U+sum nu_i(D_i h)<=U`. Reverse both signs for a lower bound. Candidate discovery can use polynomial SOS, piecewise bases or learned h; proof verification must be independent.

1. Implement exact coefficient arithmetic for low-degree polynomials and simple rational domains first. Store h, U/L, every domain inequality and an admissibility/integrability justification.
2. For bounded domains, verify interval or rational SOS positivity with an actual proof object. For unbounded domains, supply a global tail argument or polynomial certificate covering infinity; a large sampled box is not enough.
3. Keep numerical optimizer output, rational reconstruction and verified result separate. If reconstruction destroys positivity, return an unverified candidate. Do not inflate bounds by an arbitrary epsilon and call them rigorous without bounding all rounding effects.
4. E04 with g(z)=z and h=z^2/2 gives `g+Lh=1` and h'(0)=0: exact lower=upper=1. This fixes both interior and boundary signs before more complex work.

**Outputs/tests:** metric interval, source assumptions, witness h, machine-checkable proof terms and a standalone verifier result. E04 equality, bounded E05 inequality candidates, deliberate sign/rounding/tail counterexamples, and failure to certify without suppressing other estimates. No general hierarchy-convergence promise. **Tradeoff:** strongest confidence story, often much harder than obtaining a good point estimate.

### A26. Two-dimensional RBM kernel / boundary-value transforms

**Owner:** complex-analysis numerical agent. **Scope:** proposed `infinite/rbm_transform_2d/` with `kernel.py`, `branches.py`, `boundary_transform.py`, `transform.py`, independent fixtures. **Build:** D2. **Depends:** F00/A21, E06/E07. **Effort:** H-R. **Source:** P21 v3, theorem 1 and eqs (5)-(14), subsequent drift cases.

1. Use internal paper coordinates theta for `E[exp(theta.Z)]` and expose an LST wrapper with theta=-s. Require Sigma positive definite and the theorem's stable reflection conditions. Start well-conditioned cases but retain the theorem's broader stable drift cases in the design; a positive component of b alone is not a universal rejection criterion.
2. Form quadratic kernel `gamma(theta)=0.5*theta^T*Sigma*theta+b.theta`, and linear gamma_i=r_i.theta. Implement both quadratic roots, discriminants and branch points from eqs (7)-(8), with explicit continuous square-root branch selection and complex conjugacy tests.
3. Implement the conformal gluing map w, boundary curve parameterization and multiplicative boundary-value coefficient G from eqs (9)-(13). Determine pole/index cases (including chi and p) from the theorem, not by fitting a contour to a successful output. Unwrap logarithm phase continuously along the contour.
4. Evaluate theorem 1's normalized Cauchy-type integral by adaptive complex quadrature with endpoint/asymptotic subtraction. Anchor phi_i(0)=beta_i. Obtain the second face transform by a verified coordinate swap; this must swap R rows/columns, b and Sigma consistently.
5. Recover the interior transform from the BAR off the kernel. At kernel zeros use an analytic removable-limit construction or local series, not division by a tiny number plus arbitrary regularization. Track branches, poles, quadrature tolerances and the admissible complex domain.

**Outputs/tests:** interior/face transform evaluators, beta, complex-domain validity, kernel/branch diagnostics, then marginal/weighted-sum distributions through A27. E06 algebra T2; E07 via independent density integral and means; E08 d=2; coordinate swap and column rescaling; near-branch-point evaluation; stable cases with one nonnegative drift; covariance degeneration must return unsupported or a separately proved limit. **Tradeoff:** powerful independent distributional solver, specialist branch/contour numerics. Do not generalize this algorithm to boxes or d>2 without a new derivation.

### A27. Shared PGF/LST inversion and distribution queries

**Owner:** transform-service agent. **Scope:** proposed `common/qnet_transforms/` and tests; Swift result adapter owned by integration agent. **Build:** D2. **Depends:** F00; usable before A26/A29 via exact transform fixtures. **Effort:** H. **Sources:** P25/P46/P18 and official mpmath documentation.

1. Define callable transforms with exponent convention, support, analytic/evaluation domain, derivative ability and absolute/relative forward error if known. For integer N, `L_N(s)=G(exp(-s))`; this is a composition, not the Laplace integral of G. Extract a discrete PMF from PGF coefficients by a radius-controlled Cauchy/FFT method, with alias/truncation checks.
2. For nonnegative continuous X: inverse LST of phi gives density where it exists; phi/s gives CDF; `(1-phi)/s` gives survival. Use cancellation-safe evaluation near s=0. Handle atoms explicitly. A jump discontinuity inversion may return a midpoint; do not confuse it with a right-continuous discrete CDF.
3. Implement at least two independent inversion families: Fourier/Euler or de Hoog/Cohen and Talbot. Record precision, contour nodes, method/degree and refinement. Talbot can require analytic continuation outside the right half-plane; refuse evaluation outside the transform's supported domain rather than extrapolate a neural network silently.
4. Marginal queries evaluate phi(s*e_i); nonnegative weighted sums use phi(s*a). General joint threshold events require multivariate inversion/integration and are a later distinct capability. Queue residence-time distributions are not obtained from Little's law; only means are linked that way.

**Outputs/tests:** density/CDF/survival/quantiles with support/atom definitions, inversion refinement and domain warnings. E01 geometric PGF, E02 waiting LST with atom 1-rho, E04 exponential, E08 sum law, an Erlang density and a two-rate mixture. Use analytic rather than same-routine inversion truth. Test t=0 separately, repeated rates, tiny tails, conjugate symmetry and noisy-transform perturbations. Proposed T2 gates apply to exact transforms; forward approximation error is extra. **Tradeoff:** reusable across many methods, cannot repair an incorrect transform.

### A28. Compensation method for selected two-dimensional chains

**Owner:** structured-random-walk research agent. **Scope:** proposed `infinite/compensation_2d/`. **Build:** D1/D2. **Depends:** F00/A02 oracle. **Effort:** H-R. **Source:** Adan-Wessels-Zijm primary paper record and P49 dissertation (not downloaded).

**First milestone is a source-resolution gate.** Acquire the full authorized derivation for one named model, such as the applicable shortest-queue formulation. Record its state transformation and permitted interior/boundary jumps. The primary abstract alone is not enough to implement or validate compensation.

Then implement: (1) the interior kernel root pairs for product terms; (2) an initial term satisfying one boundary; (3) recursive alternating compensation of the other boundary; (4) normalization of the convergent series and a justified remainder estimate; (5) stable evaluation with signed terms/cancellation control. Each added term must reduce the intended boundary defect without violating the interior equation. A large number of terms plus small last term is not by itself a proven tail bound.

**Outputs/tests:** selected-state PMF and tails/means, root/coefficient sequence, normalization and both boundary residuals, tail/remainder evidence and model-admission checks. Validate a product-form reduction and a small named non-product case against independently converged sparse CTMC. Store a fully specified paper fixture before declaring paper reproduction. Reject unsupported jumps/routing or dimensions. **Tradeoff:** very accurate special solutions, restrictive structure and currently missing full-text prerequisites. Completion must not be faked with a generic truncation solver relabeled as compensation.

### A29. Dai-Zhang neural Laplace-BAR: reproducibility and research track

**Owner:** neural-transform research agent, with independent mathematics/oracle reviewer. **Scope:** proposed `infinite/neural_bar/` containing `physics.py`, `network.py`, `losses.py`, `sampling.py`, `train.py`, `evaluate.py`, `checkpoint.py`, `configs/`, and `tests/`. These names are a future design, not existing files. **Build:** D4; A27's D2 oracle/inversion. **Depends:** F00/A21/A27, E07/E08 validated independently. **Effort:** R. **Source:** P16 v1, sections 2-3, Appendices A-B; authors' public NN4MGF repository.

#### A29.1 Resolve paper/code conventions before training

Keep a `reproduction_notes.md` with the local PDF hash, chosen author-code commit, source license, and every departure. The repository was accessible and labeled MIT on its page during planning, but a pinned commit and full license text were not retrieved; inspect and preserve the actual license before copying anything. Do not assume current `main` exactly matches the July paper, and do not execute repository scripts on import. Author code is a reference to compare, not the sole oracle.

Five checks are mandatory:

1. **Transform sign.** The PDF defines an LST with exp(-theta.Z), but Appendix A displays product factors with denominator alpha-theta, an MGF convention. The public tests also call an MGF network at negative LST arguments. Use one internal convention with an explicit conversion; test E04 and E08 complex values before loss optimization.
2. **Density exponent.** Use E07's r^(-1/2) density, verified against P24 and `test_2d_harrison.py`; the r^(+1/2) printed on P16 p11 is inconsistent with the known moments. Normalization alone will not detect it. Record the discrepancy rather than silently using the incorrect benchmark.
3. **Pairwise reflection direction.** With column reflection, eliminating all boundary terms except k requires `(R^T*s)_j=0` for j!=k, not a row-removal rule applied to R without transposition. Construct `v=solve(R^T,e_k)` and `s_tilde=v*(s_k/v_k)` if v_k is safely nonzero; verify all unwanted dot products vanish. If it is singular/ill-conditioned or outside the allowed analytic domain, skip this penalty point with diagnostics. Do not take an uncontrolled complex logarithm through zero or a branch cut.
4. **Boundary dependence.** On orthant face k, remove or mask s_k so phi_k cannot depend on that normal coordinate. Anchor phi_k(0)=beta_k and phi_0(0)=1; beta=-R^-1*b under the admitted conditions. Interior and boundary transforms cannot all be normalized to one.
5. **Architecture expressiveness.** The section 2.3 formula adds coordinate-wise log contributions. For a fixed model this implies `log phi(s)=sum_j h_j(s_j)`, hence mixed second derivatives of log phi are zero. If it is a valid joint transform, it describes independent coordinates. E07 has Cov(X,Y)=3/32, so the literal additive architecture cannot reproduce its full joint law. This is a mathematical limitation to test, not an inference that every plotted aggregate tail is wrong. The public `fit_mgf.py` viewed during planning also contains additive aggregation; recheck the pinned revision and any alternate experiment architecture. Coordinate/boundary embeddings can add dimension-dependent parameters even when MLP weights are shared; report actual parameter and activation counts instead of promising dimension-free cost.

These findings refine the preceding survey: A29 remains interesting, but full non-product-form distribution claims require a dependence-capable architecture and independent verification. If exact paper reproduction cannot be reconciled, deliver a documented partial reproduction and do not fabricate matching results.

#### A29.2 Baseline architecture, losses and sampler

Implement **A29a** as a clearly labeled paper-style additive baseline, then **A29b** as a separate dependence-capable experimental extension (for example a nonlinear pooled/attention interaction over coordinate features). A29b changes the model class and must not be called a verbatim reproduction. Do not initialize using ground-truth transforms and then report physics-only unsupervised success; supervised oracle fits are diagnostic experiments with separate labels.

The paper's configuration to record: Fourier feature parameter H=64; coordinate/boundary embeddings of dimension 64; two 128-unit hidden layers with SiLU; AdamW with cosine schedules. The text uses logarithmic frequency endpoints -4,1/2; reconcile whether these are base-10 exponents with the selected author code before constructing the frequency grid. Input normalization to [-1,1] and embedding implementation must be explicitly captured in config. No arbitrary hidden implementation default may be omitted from reproducibility metadata.

Learn complex log transforms f_k, with phi_k=exp(f_k), or a documented alternative where log zeros make that unsuitable. Implement:

- Relative BAR residual using stable scaling `nu=max_k(log|gamma_k|+Re(f_k))`, then compare scaled left/right complex sums. Zero coefficients/origin need a finite special case. For every complex squared loss use a real nonnegative modulus-square, not a complex algebraic square passed to the optimizer.
- Pairwise interior/face consistency at points satisfying the verified dot-product construction above. Prefer a branch-invariant equation residual when logarithmic phase cannot be made consistent; label that change.
- Monotonicity on the **real nonnegative LST axis** and imaginary-part zero there. Extend derivative-sign checks beyond first order in validation; a first-derivative penalty does not ensure complete monotonicity.
- Cauchy-Riemann penalties for real/imaginary derivatives, plus conjugate-symmetry validation. Automatic differentiation must retain the graph for backpropagation through derivatives.
- Normalization at zero and face-mass anchors. Exact architectural anchoring versus the paper's soft penalty is a documented ablation.

Sampling follows the paper's two-stage corner-biased procedure: sample scalar real/imaginary reference thresholds, then sample coordinates conditionally nearer the low-real and large-|imaginary| regions. Add explicitly labeled holdouts on axes, near zero, kernel neighborhoods, and actual inversion contours. A29b may add further sampling but must retain baseline comparisons. The supported complex evaluation domain must contain the query contours, or the query must be refused. Changing a contour's precision/degree can change that domain.

#### A29.3 Training budget, checkpoints and reproducibility

Paper schedule: 16,384 sampled points per update; 100,000 updates, learning rate 1e-3 ->1e-4. For 20D/30D, two further 100,000-update stages, 1e-4 ->1e-5 and 1e-5 ->1e-6. Expensive pairwise penalty uses 300 points; derivative penalties use an interior 1,024-point subset and an all-functions 128-point subset. Printed penalty weights are 10 for pair/boundary, monotonicity and CR, 0.1 for zero anchor. The separate imaginary penalty and optimizer defaults must be resolved from the pinned implementation and stored; the paper alone does not specify every knob.

Do **not** launch this full schedule automatically. Proposed development profiles:

| Profile | Purpose | Initial cap |
|---|---|---|
| CPU smoke | Forward/loss/autograd/checkpoint plumbing on 1D/2D exact models | 50 updates, batch 64; no accuracy claim |
| Small experiment | Compare additive and interaction architecture on E07/E08 d=5 | 2,000 updates, pilot measured memory/time; scientific acceptance separate |
| Paper reproduction | Match recorded schedule/config on E07 and d=20/30 | Explicit user-approved time/device budget and full parameter log |

Use CPU float64/complex128 as the reference. Test any accelerator/float32 profile against it on small cases, including second-order autograd through CR loss. If complex support or precision is insufficient, fall back explicitly or fail, not silently change arithmetic. Gradient accumulation can preserve total batch loss if reduction/weights are handled correctly; test it against an unsplit batch. Save RNG states, optimizer and scheduler state, step number, architecture, all penalty weights, physics matrices/hash, domain, dtype and package versions. Resume must reject a changed physics model or incompatible configuration. Write checkpoints atomically outside app resources; do not fetch remote checkpoints automatically. A model is trained for a specified RBM unless an explicitly validated parameter-conditioned design says otherwise.

#### A29.4 Outputs and staged scientific gates

Required outputs: interior/face transform queries with supported domain, boundary rates, selected means/raw seconds/covariances, weighted-sum survival/CDF/quantiles via A27, training/holdout loss by component, monotonicity/CR/conjugacy checks, checkpoint provenance, and explicit invalid/unavailable metrics. A bounded parameter-free 'joint distribution' label is not sufficient.

1. **Physics/oracle gate:** exact E04/E06/E08 transforms satisfy the implemented BAR to T0 independent of any neural network. E07 density moments and tail quadrature match section 4. Deliberately wrong sign/transpose/exponent must fail tests.
2. **Representation gate:** fit/check E08 and separately E07. For the additive baseline, demonstrate the zero mixed-log-derivative restriction and do not claim it passed a correlated joint-law test. A29b must represent nonzero cross covariance before physics-only training is evaluated.
3. **Numerical gate:** separate forward-transform error from inversion error. Invert exact E08 transforms through A27 and compare with the closed sum CDF. Then evaluate learned transforms at the same contour nodes. Increasing mpmath precision cannot recover information lost by conversion to a lower-precision neural evaluator.
4. **Small-case acceptance:** proposed target on E07/E08 d=2/5: mean and raw-second relative errors <=2%, E07 covariance absolute error <=0.01, CDF absolute error <=0.01, and survival relative error <=5% on the fixed t-grid where the true tail>=0.01. These are Qnet targets, not paper guarantees. Report all metrics even when only some pass.
5. **Scale acceptance:** d=20/30 E08 must satisfy mean relative error <=5%, nonnegative second moments/PSD covariance diagnostics, and sum survival relative error <=5% for predeclared tails >=0.01. Do not claim general correlated high-dimensional accuracy from this product-form family. A correct exact-product detector should bypass training for ordinary user runs; these are research benchmarks.
6. **Robustness gate:** run predeclared seeds 11,29,47,71,101, preserve failed seeds and dispersion; test at least one 3D genuinely coupled model with independent spatial/CTMC-approximation or carefully refined RBM simulation reference before exposing A29b as a correlated solver. Use new models for validation, not only new transform points on training models.
7. **Safety gate:** inject negative raw second moments (including B06), covariance inconsistency, out-of-domain requests, missing GPU support, interrupted training and malformed checkpoint. Return partial/failed results appropriately; no clipping impossible moments into apparently valid output.

**Tradeoff:** potentially flexible transform approximation, but substantial compute, possible non-identifiability, transform-validity/analytic-domain constraints and a real architecture expressiveness issue. A29 remains opt-in experimental even if its selected benchmarks pass. It does not certify queue tails or residence-time distributions.

### A30. Perfect stationary sampling for supported GJNs

**Owner:** exact-simulation research agent. **Scope:** proposed `infinite/perfect_gjn/`; reuse distribution primitives only after coupling compatibility checks. **Build:** D0/D1. **Depends:** F00, validated ordinary DES and E01/E02. **Effort:** H-R. **Source:** P41 sections 2-7, Algorithms 1-4.

1. Implement the paper's supported FIFO, single-server, infinite-buffer network and all assumptions, including stable traffic, continuous primitive distributions for the stated version, light exponential moments, unbounded interarrival support, and the required uniform conditional-excess/envelope/tilting samplers. 'Finite MGF' alone is not the whole executable admission condition.
2. Implement and unit-test the auxiliary slowed network, vacation domination and autonomous-queue bounding processes. Couple service/routing streams exactly; fresh independent randomness on replay destroys coupling from the past.
3. Build stationary backward renewal/random-walk sampling with the paper's exponential tilting/rejection construction. Implement coalescence detection and replay to time zero with persistent random streams and a pathwise dominance assertion in small tests.
4. Resource limits stop sample production cleanly. A history that has not coalesced is **not** an approximately perfect sample; expose no sample for that attempt. Do not select only fast-coalescing runs for statistical validation, which can bias the sample set.

**Outputs/tests:** exact-stationary samples within the numerical/randomness implementation contract, service/residual state where required, coalescence history/cost, and Monte Carlo moments/intervals across completed independent samples. E01 geometric PMF and E02 exact mean; two-node Jackson product form; stationarity under forward evolution; replay determinism and deliberately violated coupling. Heavy-tailed or bounded-support primitives outside admitted assumptions must be rejected. **Tradeoff:** removes initialization bias, not sampling error or potentially large random runtime.

### A31. Rare-event importance sampling and splitting

**Owner:** rare-event simulation agent. **Scope:** extend `infinite/regenerative_mc/` through an isolated general event estimator or proposed `infinite/rare_event/`. **Build:** D0/D1. **Depends:** F00, exact event oracles, A02/small CTMC. **Effort:** H. **Sources:** P32, P33 (full splitting derivation still needed for that named variant).

1. Require an explicit event/observable: hitting overflow before return to empty, finite-horizon loss, stationary tail reward, or stationary loss fraction. They are different quantities and must use different estimators.
2. First implement a two-node Markov tandem state-dependent tilt using documented likelihood ratios for event choices and holding times; accumulate log weights. If uniformization is used, its self-transitions/proposal probabilities are part of the likelihood.
3. For stationary tails use a valid stationary-sampling or regenerative reward/length formulation. Weight the reward and denominator correctly; a ratio of estimated expectations is generally not finite-sample unbiased. Record return-cycle integrity and moments needed for intervals.
4. Add splitting with predeclared levels and independent particle-family accounting. Adaptive levels require a method-specific variance/interval analysis; do not treat all descendant particles as independent Bernoulli trials.

**Outputs/tests:** named event estimate, interval type, event/particle/cycle counts, log-weight diagnostics, effective information and cost. For an embedded M/M/1 birth-death walk with arrival=2, service=3, the chance from state 1 to reach K before 0 is `((3/2)-1)/((3/2)^K-1)`; for K=5 it is 16/211. Test this independently of E01's **stationary** tail `(2/3)^5`. Null tilt must reproduce ordinary Monte Carlo, and exact CTMC hitting equations validate small tandem cases. Require correct expectation before claiming variance reduction; poor tilt can worsen it. **Tradeoff:** rare-event efficiency, substantial estimator/weighting risk.

### A32. Poisson-equation martingale controls and learned test functions

**Owner:** simulation-control agent. **Scope:** proposed `infinite/poisson_controls/`, adapters to simulation; optional D4 learner separate from deterministic reference. **Build:** D1; D4 optional. **Depends:** F00/E14, exact generator evaluator. **Effort:** H-R. **Sources:** P31/P39/P44.

1. For finite CTMC Q and reward g solve `Qh=-(g-c)`, `pi*h=0`, with c=pi*g in the oracle case. Test independently on a two-state chain and E03. Then fit an approximate h without using unknown exact c as a claimed available input.
2. During a CTMC path compute `M_t=h(X_t)-h(X_0)-integral_0^t Qh(X_s) ds`. Under the required integrability this is a zero-mean martingale. Use `g_average - a*M_t/t`, with a fixed coefficient or one learned from independent pilot data/cross-fitting. For the exact h and a=1 the remaining error is an endpoint term; it is not generally identically zero on finite stationary-time windows.
3. A diffusion/learned h can be useful, but evaluate **the actual simulated process generator Qh**, not its approximate diffusion generator. For general renewal queues augment residual service/arrival ages and account for deterministic motion/jumps; unsupported Markovization must be refused.
4. Neural Lyapunov/Poisson functions from P44 are candidates. Use A25 for any global proof claim and held-out trajectories for efficiency evaluation. Training on the same outcome used to choose the best reported coefficient requires a valid bias/variance treatment.

**Outputs/tests:** ordinary and controlled estimates/intervals, coefficient, martingale sample mean, residual diagnostics, variance ratio and variance-times-wall-clock efficiency, plus fitted-function provenance. E14 Poisson algebra T0; finite-chain control expectation matches baseline; intentional wrong-generator test detects bias; independent seeds show measured rather than assumed efficiency. Time-average warm-up bias is not removed merely by a zero-mean control. **Tradeoff:** leverages existing approximations to save simulation cost, but evaluation overhead and model mismatch can eliminate the gain.

## 7. Proposed hybrid projects H1-H6

These are Qnet-specific designs with literature-inspired ingredients, not asserted new theorems. Keep their method IDs, experimental labels and validation separate from the component solvers. Each needs a later explicit assignment.

### H1. Point estimate plus independently verified BAR interval

**Owner/files:** certificate-integration agent, proposed `infinite/hybrid_bar_certificate/`. **Build/dependencies:** D1/D3, A22/A23/A29 candidate interface and A25 verifier. **Effort:** H-R.

Use a point solver to suggest a density/Poisson basis, solve dual lower/upper metric problems, then verify witnesses independently. Require matching model hash, coordinates, metric units and diffusion domain across components. Stop when a verified interval width meets the user's absolute/relative target; if verification fails, keep the point estimate labeled unverified and report the failed certificate separately.

**Expected outputs/tests:** point value, verified interval or explicit failure, witness, numerical versus model-error labels. E04 must produce [1,1]; E05 bounded mean must lie within its valid interval; E07 is the first coupled case. Deliberately give the verifier a witness trained on a different model or opposite reflection convention and require rejection. No claim that the interval bounds the original queue unless a separate queue-to-diffusion bound exists. **Benefit/risk:** confidence around estimates; tight proof may cost much more than the estimate.

### H2. Discrete boundary-region CTMC coupled to a diffusion tail

**Owner/files:** hybrid-domain research agent, proposed `infinite/hybrid_discrete_diffusion/`. **Build/dependencies:** D1/D2, A01/A02/A22 or A09. **Effort:** R.

Start with one PH queue: retain exact low-count states through interface K0 and use phase-conditioned continuous tail beyond it. Derive interface probability-current equations from integrated generator balance, allocate disjoint probability mass to the two regions, and match the appropriate moments/flux. Do not average two complete normalized laws. A queue-to-diffusion scale and a phase-transition treatment are part of the interface model.

**Expected outputs/tests:** discrete head PMF, tail density/transform, interface flux, total mass, means/tails and interface-sensitivity sweep. E01/E02 versus exact/QBD oracle at K0=2,4,8,16; ensure no duplicate mass or negative probability and check movement of interface does not produce large discontinuities. Only then try a two-node PH network. There is no inherited rigorous error bound; require a new derivation before labeling one. **Benefit/risk:** retains discrete boundary behavior, difficult conservation/closure and possible interface bias.

### H3. Two-dimensional transform blocks inside network decomposition

**Owner/files:** block-decomposition research agent, proposed `infinite/hybrid_transform_blocks/`. **Build/dependencies:** D1/D2, A26/A27 and a documented decomposition closure. **Effort:** R.

Select nonoverlapping or explicitly coordinated bottleneck pairs in a three/four-node network. Construct each local RBM from a declared effective input process, solve its transform, and pass consistent flow/moment information to neighboring blocks. Begin with disjoint blocks and one-way routing; feedback/overlap is a later milestone. Define the fixed-point variables and how a transform is approximated when converting to a queue arrival process; a workload transform is not automatically an interarrival transform.

**Expected outputs/tests:** block laws/covariances, global approximate means/selected tails, shared-flow residual and iteration history. Entire two-node network must reduce to A26; disconnected blocks reproduce independence; a three-node tandem compares with full SRBM and DES separately. Include a test that exact local blocks do not receive a global-exact claim. **Benefit/risk:** preserves pair dependence cheaply, loses inter-block dependence and may have difficult fixed points.

### H4. Positive dependent distribution/transform mixture

**Owner/files:** positive-representation research agent, extend `infinite/adaptive_srbm/` in isolated `dependent_components.py`. **Build/dependencies:** D1/D2, F00/A21/A26 or A01 tractable components. **Effort:** R.

Use convex weights over normalized nonnegative joint components, with at least one component family that has **within-component dependence** (such as validated 2D transform blocks or a nonnegative latent-factor PH construction). Fit corresponding boundary measures, not merely the interior distribution. Keep beta normalization and face support separate. Use BAR training and independent transform/moment validation; rank/component growth needs a memory estimate and stopping rule.

**Expected outputs/tests:** mixture specification, transform queries, moments/covariances, valid samples where available, held-out BAR residual. E06 product form is a reduction; E07 nonzero covariance and tail values are mandatory; a synthetic correlated positive law checks representation before stationary fitting. Compare with the existing separable exponential-mixture baseline rather than relabeling it. Positive representation prevents impossible moments but does not establish that the fitted law is stationary. **Benefit/risk:** structural probability validity, component bias/optimization cost.

### H5. Distribution-shape sensitivity and solver-disagreement analysis

**Owner/files:** robustness orchestration agent, proposed `validation/model_sensitivity/` plus later GUI integration. **Build/dependencies:** D0/D1, at least two scientifically distinct solvers and distribution-input support. **Effort:** H.

Given mean/SCV inputs, construct explicitly admissible families with identical moments and different shapes, or accept user-provided traces/laws. Validate moment matching analytically before running scenarios. Preserve source-stream dependence as a separate scenario dimension. Schedule exact/fitted Markov, diffusion and DES runs with the same physical model semantics, cache by immutable fingerprint, and allocate additional authorized computation to unresolved discrepancies.

**Expected outputs/tests:** scenario definitions, per-method predictions, numerical/statistical uncertainty, approximation discrepancy and a sensitivity envelope. Use E02 and two PH service laws with matching moments but different third moments in a two-node network; M/G/1 mean wait is a useful invariant when the first two moments are fixed, whereas distributional metrics can differ. An envelope over finitely many laws is not a rigorous worst-case bound or confidence interval. No automatic model correction. **Benefit/risk:** exposes missing-input sensitivity, requires careful interpretation and can multiply run cost.

### H6. Reliability-state switching diffusion

**Owner/files:** manufacturing diffusion research agent, proposed `finite/switching_diffusion/`. **Build/dependencies:** D1/D2, A06/A08/A09 and machine-state schema. **Effort:** R.

Represent finite environment e with generator T and level diffusion with regime-specific b_e, Sigma_e and reflection. The generator for vector test functions is `L_e f_e + sum_(e'!=e) T_ee'*(f_e'-f_e)`. Solve coupled stationary weak equations plus regime-specific boundary conditions and joint normalization. Define whether environment transitions change physical inventory; ordinary reliability switches do not reset it. Zero covariance in a down state requires a mixed fluid/diffusion treatment or explicit unsupported result, not arbitrary noise.

**Expected outputs/tests:** joint inventory/environment density and atoms where the chosen process permits them, throughput/reward estimates, face rates and switching balance. With identical diffusion coefficients in every regime, recover product of the level law and environment stationary distribution; with zero diffusion and supported boundary semantics reduce to A08; with one regime reduce to A09. Compare one-buffer/two-machine cases to exact fluid/discrete references with approximation labels. **Benefit/risk:** retains long failures and inventory dependence, singular regimes and boundary coupling are hard.

## 8. Foundation/reference tasks and sub-agent execution order

### 8.1 F01: reference simulation and reproducible fixtures

**Owner:** independent reference agent. Proposed scope `validation/research_reference/` and `validation/research_fixtures/`; production DES changes require a separately authorized integration task. D0/D1. Depends on F00's model contract, not on the candidate solver.

Implement a transparent small-model event simulator with a time-weighted reward accumulator, immutable input, event log option and independent random streams per primitive. Milestones:

1. Exact Markov arrival/service queues E01/E03/E12, with independently enumerated transition rates and stationary law.
2. Preemptive-resume re-entrant priorities B01/B02: persistent job/stage IDs, remaining service and within-class FCFS; process event-time ties by an explicit deterministic rule. General-law service must resume the same remaining requirement after preemption, not resample it.
3. Closed fixed-population models E09/E13: initialize exactly N_r class-r jobs, no exogenous arrivals, check population after every event and integrate reward during idle/blocked periods.
4. Reliability and fluid references: distinguish random service completions from deterministic material flow between Markov environment events. Fluid simulation integrates to the next environment change or buffer-hitting time and applies physical boundary behavior.
5. Diffusion reference for E07/E10: use an explicitly documented reflection discretization, not coordinatewise clipping for oblique R. Compare at nested time steps with common Brownian increments where valid, separate warm-up/horizon/time-step effects, and verify exact marginals first.

Export a trajectory/reward diagnostic schema, replication-level observations and confidence-interval metadata. A priority queue mean is **time-average** occupancy unless explicitly labeled arrival-epoch. Check Little's law against completed-job sojourn with appropriate finite-run censoring; jobs still present at the end cannot simply vanish from a sojourn denominator.

Paper simulation budgets (for example P12's 10^8 arrivals and 20 replications) are historical reproduction configurations, not compulsory unit tests. Establish shorter pilot precision goals, then request authorization for long runs. For stiff/near-critical cases, failure to reach useful precision is an informative incomplete result, not a valid zero-width interval.

### 8.2 F02: benchmark serialization and independent oracle ownership

Before solver implementation, create the E/B fixtures with this proposed structure:

```text
validation/research_fixtures/<fixture-id>/
  input.json
  expected.json
  provenance.md
  oracle.py             # only when formulas need computation
  test_oracle.py
```

Every `expected.json` must contain evidence type, source paper ID/hash/page/table or derivation, model hash, observable names/units, raw-versus-central moment distinction, values/formulas, tolerance and known limitations. For historical simulation keep mean, stated CI half-width and level if known; mark missing confidence information, rather than assigning 95% by assumption. Preserve fractional/rational exact expectations as strings alongside decimal display values where useful.

Expected values must not be regenerated automatically by the algorithm being tested. The oracle owner reviews modifications to expected outputs; a failing test cannot be repaired by replacing its expected value with the new solver output. Store golden input hashes with checkpoints and result archives. Run publication-table comparisons separately from exact-oracle tests, because a legitimate algorithmic improvement can differ from an old approximate table.

### 8.3 Ownership and merge discipline

The user asked for instructions usable by future sub-agents; this plan did not launch implementation agents. When parallel implementation is later authorized, prefer an integration lead and at most three independently bounded agents per batch on a four-slot environment. Re-evaluate actual available concurrency then.

| Work batch | Independent assignments after prerequisites | Lead/integration responsibility |
|---|---|---|
| Foundation | F00 contracts; F01 references; F02 paper/exact fixture transcription | Freeze schema/units and verify E/B inputs; resolve shared ownership |
| Core coverage | A10 closed MVA; A15 priority mapping; A01 PH/MAP | Keep current source/app launch and baseline methods unchanged |
| Distribution infrastructure | A27 inversion; A21 exact structure; A09 bounded BAR | Shared transform/domain interface and BAR sign tests |
| Rich numerical models | A26 2D transform; A06/A08 manufacturing blocks; A16 priority multiscale | Cross-solver fixture harness; no overlapping file edits |
| Model expansion | A07/A14 transfer/closed loops; A17/A18 OU/many-server; A11/A12 larger closed networks | GUI schema migration only for validated model families |
| Confidence and simulation | A02/A24/A25 bounds; A30/A31 sampling; A32 controls | Independent verification and statistical validity review |
| Research frontier | A29a/A29b; A04/A05; H1-H6 as separate bounded experiments | Budget approval, paper discrepancy log, explicit experimental labels |

A13/A19/A20/A28 require their specific full-model derivation/source gates before assignment to generic implementation work. Do not treat the batch table as a strict requirement to wait for unrelated projects: A27 can be implemented immediately from exact oracles while priority work proceeds. H1 can begin once A25 and any point solver work; it does not depend on successful neural research.

Shared files that need a single integration owner include `Models.swift`, `QnetGUIApp.swift`, `ResultsWorkspace.swift`, `ResultOutputParser.swift`, `StartupDependencyChecker.swift`, `MethodChooserView.swift`, `AnalyticalTractability.swift`, `RunParameterSpecs.swift`, `build_all_algorithms.sh`, `build_app.sh`, release inventories and shared schemas. An algorithm agent should deliver an adapter contract and tests rather than independently patch these while another agent is working there.

### 8.4 Copyable future assignment template

Use the following as a future task specification, filling its fields explicitly; it is not an instruction to execute now:

```text
Implement [A/H ID and milestone] in the current Qnet project.
Read Plans.md sections 0-5, your project card, and sections 8-12.
Authorized file scope: [exact directories/files].
Shared integration owner: [name/task]; do not edit shared files without coordination.
Prerequisite artifacts and versions: [schemas, fixtures, solver APIs].
Required sources: [paper IDs, local PDFs, exact pages/sections].
First deliverable: independent oracle tests for [E/B IDs].
Required algorithm outputs: [contract names from card].
Build/dependency profile: [D0-D5]; installations or paid/remote compute require approval.
Acceptance: [test classes, exact tolerances, adverse cases, resource limits].
Out of scope: [unadmitted disciplines, GUI/release changes, optimization/control].
At handoff include changed files, commands/results, source assumptions, input hashes,
remaining gaps and whether any model or certificate claim is still unverified.
Do not call incomplete or unsupported science a successful implementation.
```

### 8.5 Handoff record required from every agent

Record task ID/milestone/status; source revisions and PDF hashes; mathematical conventions; file changes; dependencies and exact lock versions; oracle origins; commands with exit results; numerical tables and statistical metadata; failure/adverse cases; resource use; unresolved issues; and the next concrete action. Include an explicit claim classification for each output. Proposed durable location is `docs/implementation/<ID>_handoff.md`, with code/test paths; creating those files is future work, not part of this plan-only turn.

## 9. GUI and app integration plan (after numerical validation)

No GUI changes are authorized now. When requested later, integrate one admitted model family at a time rather than exposing every experimental method in the existing open-network menu.

1. **Versioned document inputs:** preserve old defaults; add explicit priorities, closed class populations, polling cycles, machine states and capacity semantics only with round-trip/migration tests. Read/write older files without losing unknown/new fields where the selected format supports preservation. Do not infer closed populations from a canvas cycle.
2. **Admission:** show model applicability and dependency readiness separately. A supported model with a missing Python module receives install guidance; an unsupported scheduling policy receives a mathematical explanation. Do not offer package installation as the fix for an unsupported model.
3. **Dependency checklist:** keep optional D1-D4 groups separate; show the exact interpreter/device being tested. Homebrew installs system tools, pip installs Python modules into the selected environment. Checkmarks mean the probe actually passed, not just that the package name exists. No automatic network fetch or installation on startup.
4. **Run parameters:** model fields are not solver tuning knobs. Expose resource caps, accuracy target, seed, approximation variant, and result domain. Neural training versus checkpoint evaluation must be different actions with a visible cost warning and cancellation.
5. **Typed results:** retain station/class populations and their physical units. Add separate distribution/transform/boundary-rate payloads and experimental warnings. A mean-only method must not enable CDF export. Hide no invalid metrics; display why they failed. A law on centered R^d coordinates is not a nonnegative queue-count distribution.
6. **Comparison:** compare the same observable/model fingerprint and show numerical versus queue-model versus sampling error. Mixed-model comparisons must explicitly state the difference. A diffusion certificate does not bound a queue by association. Store all methods' failures, not only successful rows.
7. **Headless path:** add appropriate exporter/runner tests patterned after current `validation/*_check.sh` checks. Proposed CLI options must be documented and tested; the new standalone JSON contracts can precede a GUI integration. Do not claim a headless option exists until it is implemented.
8. **App resources:** verify the actual resolved executable/script in both source and app launches. Packaged copies have precedence, so rebuilding loose solver code alone may not test the change. Use the documented source override where effective or an isolated source-only staging copy for development, then rebuild the app for release. Never delete the user's existing app just to force source resolution.
9. **Design/accessibility:** reuse the existing DS components/tokens and run `validation/design_lint.sh` for actual UI edits. Warnings/status must not rely solely on color; keyboard, VoiceOver, cancellation and long-output behavior need checks.

## 10. Acceptance and reproducibility matrix

### 10.1 Minimum tests by project

| Project | Mandatory exact/reduction oracles | Paper/independent scientific comparison | Additional critical rejection test |
|---|---|---|---|
| A01 | E01,E02 | MAP/PH case versus independently built CTMC | Improper PH / unstable QBD |
| A02 | E01,E03 | Non-product PH tandem / P26 formulation | Unjustified certificate or predecessor omission |
| A03 | Independent E01 stations | P14 formulas; load-separated DES | Routing hit probabilities / zero traffic |
| A04 | Scalar OU/E04, exact Erlang-C recursion | P17 selected model | Nonpositive effective variance |
| A05 | E03 tensor product | Coupled sparse CTMC | Rank/memory blowup |
| A06 | E12,E03 reductions | Matched BAS DES | Deadlock / missing blocked state |
| A07 | Exact two-machine block | B05 plus matched fluid DES | Nonphysical fixed-point rates |
| A08 | E11 | Multi-phase independent discretization | Lost boundary atom / critical infinite storage |
| A09 | E05,E13 | P05 selected case | Missing upper face / covariance convention |
| A10 | E09 | Existing enumeration examples | Unsupported elementary multi-server MVA |
| A11 | E09 normalizers | P29 recurrence substitution | Singular basis / multiplicity confusion |
| A12 | E09,N=1,delay centers | Exact MVA error grid | False exact/Linearizer claim |
| A13 | E13 geometry | Fully transcribed P03 case, closed DES | Lost population conservation |
| A14 | E09/E13 loop reduction | P42 chosen model | Deadlocked communicating class |
| A15 | B01 parameter matrices | B01 numerical and priority DES | Wrong discipline / workload units |
| A16 | B02 formula values | B02 published simulations / new DES | Virtual-station instability |
| A17 | E10 exact OU marginal | B04 only after parameter reconciliation | Orthant clipping / gamma sum<=0 |
| A18 | E14 exact queue reduction | P07 matching diffusion and PH DES | Overload without abandonment |
| A19 | Independent queue reductions | Tiny allocation CTMC / P08 mapping | Unsupported service-speed assumptions |
| A20 | E02 waiting LST reduction | P45 matched polling DES | Wrong observation epoch |
| A21 | E04,E06,E08 | P23 special case after transcription | Nearly skew falsely labeled exact |
| A22 | E04,E06,E07 | Existing engine and independent transform | Invalid reference tail / negative density |
| A23 | E05,E06,E07 | B03 | Grid residual falsely certified |
| A24 | E04,E05,E06 | E07 moments / independent exact bounds | Nonrealizable moments / SDP unavailable |
| A25 | E04 exact witness | E05/E07 verified inequalities | Tail/sign/rounding invalid witness |
| A26 | E06,E07,E08 d=2 | Spatial density integration | Kernel zero / branch discontinuity |
| A27 | E01,E02,E04,E08 | Independent inversion family | Domain violation / atom mishandling |
| A28 | Product-form reduction selected from full source | Named compensation case / CTMC | Unsupported boundary jump structure |
| A29 | E04,E06,E07,E08 | B06 and held-out coupled model | Impossible moments / additive dependence claim |
| A30 | E01,E02 | Jackson law / forward stationarity | Noncoalesced or censored sample |
| A31 | E01 stationary vs hitting formula | Tandem hitting equations | Wrong likelihood / particle independence |
| A32 | E14 Poisson / E03 | Independent control-efficiency runs | Approximate rather than actual generator |
| H1 | E04,E05 | E07 | Mismatched model certificate |
| H2 | E01,E02 | PH/QBD interface sweep | Double-counted mass |
| H3 | Whole 2D / disconnected blocks | Three-node full SRBM and DES | False global exactness |
| H4 | E06,E07 | Existing positive-mixture comparison | No within-component dependence |
| H5 | Moment matching / E02 | Multi-shape network scenarios | Envelope called a confidence bound |
| H6 | E05/E11 environment reductions | One-buffer reliability comparison | Invalid singular regime treatment |

### 10.2 Build/test suite layers

Create proposed `validation/research_suite.sh` during implementation with explicit profiles, not during planning:

- `--quick`: schemas, exact oracles, deterministic core solver tests, capability/error paths. No network, training, library installation or long simulation.
- `--numerical`: exact-diffusion refinement, transforms, paper deterministic examples. Prints per-method skipped dependencies distinctly from failures.
- `--statistical`: predeclared replication/seed suites with saved raw replication outputs and multiplicity-aware checks.
- `--experimental`: opted-in tensors, perfect sampling, neural small runs and hybrids with individual budgets.
- `--paper-reproduction <ID>`: full recorded source configuration and larger approved resource budget. A missing source/parameter stays a documented hold.

The existing `validation/steady_state_suite.sh` must still pass for baseline methods. Do not run an optional research package's long suite from `swift run` or app startup. Add per-module Makefile `test/check` targets only when implemented and include their paths in the future handoff.

### 10.3 Release acceptance checklist

- [ ] New inputs have precise model semantics, versioned schemas and invalid-input tests.
- [ ] Exact E fixtures and all assigned B/source comparisons have stored provenance and pass the relevant gates.
- [ ] Original queue versus diffusion and numerical versus statistical errors are separately labeled.
- [ ] Reflection orientation, covariance interpretation, units, class/stage order and population mappings are independently tested.
- [ ] Solver failure, partial completion, timeout, cancellation, memory limit and missing dependency never produce apparent success.
- [ ] Numerical method is verified through its actual CLI and its packaged/source-resolved invocation, not only by importing functions in a test.
- [ ] Shared parser/exporter/archive tests and existing regression suite pass.
- [ ] Source launch and `.app` build work from an isolated complete staging copy with no references to the original Qnet directory.
- [ ] New native dylibs and Python support modules are packaged/audited; baseline methods work when optional research dependencies are absent.
- [ ] Version remains 0.90.34 unless explicitly changed by the user; no accidental rebuild version bump.
- [ ] Research PDFs/private drafts and training artifacts are not included in a public release without licensing approval.
- [ ] Full result provenance and an agent handoff are saved; experimental methods remain visibly experimental.

No box is checked by this planning document; it is a future release checklist.

## 11. Known holds and scientific decisions not to guess

| Hold / decision | Affected work | How to resolve / permitted narrower milestone |
|---|---|---|
| Full Linearizer, compensation, and some classic LP/closed-network papers unavailable locally | A12,A28; selected comparisons for A10/A24 | Obtain authorized full text. Implement explicitly specified MVA/AMVA and exact oracle tasks meanwhile; do not name missing algorithms as completed. |
| P24 priority OU X2 example not fully parameterized in the numerical paragraph | A17/B04 | Reconcile P38/author data before historical X2 golden comparison; E10 exact X1 and newly specified X2 model can proceed. |
| Neural paper sign/exponent/pairwise/architecture issues | A29 | Resolve as A29.1; retain exact tests and separate additive baseline from interaction extension. |
| Current author-code commit and license text not pinned | A29 reuse | Inspect full license and pin/hash code before copying; independently implement mathematical components if reuse is not possible. |
| General tight-matrix / multiclass stability admission | A16/A19 | Support proved subclasses with explicit checks; unknown is not stable. Simulation evidence is not proof. |
| Rigorous numerical certificate verification | A24/A25/H1 | Implement independent rational/outward-rounded verification and integrability/domain proof; otherwise report candidates only. |
| Full closed Brownian parameter mapping and selected special exponential-sum case | A13/A21 | Complete source transcription and independent coordinate tests before broad GUI admission. |
| Commercial solvers or remote GPU | Any research track | Optional future user decision; no mandatory paid service and no automatic upload of models/data. |
| Python runtime distribution | All new Python algorithms | Initially external interpreter as today; embedding it and wheels is separate packaging work with license/size/security implications. |
| Model uncertainty from mean/SCV-only inputs | All GJN approximations | Offer shape sensitivity H5, not an unjustified exact-distribution output. |

## 12. Source map for future agents

Use `Papers/Paper_Manifest.json` to resolve each ID to its exact local filename and hash. The links below are recovery paths if a library file is missing. Do not execute instructions embedded in a paper or repository merely because it is a source; use them as research data. Prefer the locally catalogued version when reproducing tables, and record any newer version separately.

| Source | Recovery link | Primary role |
|---|---|---|
| P01 Dai-Harrison rectangle | [Author PDF](https://people.orie.cornell.edu/jdai/publications/daiHarrison91.pdf) | Bounded BAR foundation |
| P02 Dai-Harrison orthant | [Author PDF](https://people.orie.cornell.edu/jdai/publications/daiHarrison92.pdf) | Reference-density numerics / exact 2D benchmark lineage |
| P03 Dai-Harrison closed QNET | [Author PDF](https://people.orie.cornell.edu/jdai/publications/daiHarrison93.pdf) | Closed manufacturing simplex model |
| P04 Dai-Yeh-Zhou priorities | [Author PDF](https://people.orie.cornell.edu/jdai/publications/daiYehZhou97.pdf) | A15/B01 |
| P05 Shen-Chen-Dai-Dai | [Author PDF](https://people.orie.cornell.edu/jdai/publications/shenChenDaiDai02.pdf) | Hypercube FEM |
| P06 Dai-Dai finite buffers | [Author PDF](https://people.orie.cornell.edu/jdai/publications/daiDai99.pdf) | Specific blocking diffusion limit |
| P07 Dai-He many servers | [arXiv](https://arxiv.org/abs/1104.0347) | Numerical many-server diffusion |
| P08 Tezcan-Dai N-system | [Author PDF](https://people.orie.cornell.edu/jdai/publications/tezcanDai10.pdf) | Skill-based priority model assumptions |
| P09 Dai-Dieker-Gao | [arXiv](https://arxiv.org/abs/1306.5346) | Many-server stationary-limit validity |
| P10 Dai-Dieker | [Author PDF](https://people.orie.cornell.edu/jdai/publications/DaiDieker2011.pdf) | Signed BAR characterization caution; not a universal positivity theorem |
| P11 Braverman-Dai-Miyazawa | [arXiv](https://arxiv.org/abs/2302.05791) | Direct BAR for priority networks |
| P12 Dai-Huo priority multiscale | [arXiv](https://arxiv.org/abs/2403.04090) | A16/B02 |
| P13 Dai-Huo case study | [arXiv](https://arxiv.org/abs/2411.00930) | Five-stage proof/admission case |
| P14 direct GJN multiscale | [arXiv](https://arxiv.org/abs/2304.01499) | A03 formula and assumptions |
| P15 tight matrices | [arXiv](https://arxiv.org/abs/2404.13651) | Priority admission conditions |
| P16 Dai-Zhang neural BAR | [arXiv](https://arxiv.org/abs/2607.08091) | A29/B06, v1 July 2026 |
| P17 Braverman-Dai-Fang | [arXiv](https://arxiv.org/abs/2012.02824) | Higher-order stationary diffusions |
| P18 2D SRBM tails | [arXiv](https://arxiv.org/abs/1110.1791) | Tail geometry |
| P19 product-form geometry/BAR | [arXiv](https://arxiv.org/abs/1312.1758) | Exact transforms and BAR equivalence |
| P20 stationary decomposability | [arXiv](https://arxiv.org/abs/1312.1387) | Exact independent blocks |
| P21 Franceschi-Raschel | [arXiv](https://arxiv.org/abs/1703.09433) | 2D kernel/BVP transform |
| P22 wedge transform classes | [arXiv](https://arxiv.org/abs/2101.01562) | Special transform forms |
| P23 exponential-sum RBM | [arXiv](https://arxiv.org/abs/0712.0844) | Non-product exact benchmarks |
| P24 Saure-Glynn-Zeevi | [Author draft](https://www.dii.uchile.cl/~dsaure/papers/LP_SRBM.pdf) | LP/OU examples; marked not for distribution |
| P25 Abate-Whitt Fourier inversion | [Author PDF](https://www.columbia.edu/~ww2040/FourierSeries1992.pdf) | PGF/LST inversion |
| P26 CTMC truncation review | [arXiv](https://arxiv.org/abs/1909.05794) | Stationary truncation/bounds taxonomy |
| P27 moment/probability bounds | [arXiv](https://arxiv.org/abs/1702.05468) | CTMC LP/SDP foundations, not automatic RBM theorem |
| P28 truncation augmentation | [arXiv](https://arxiv.org/abs/2203.15167) | Convergence conditions |
| P29 Casale multi-branched MoM | [arXiv](https://arxiv.org/abs/0902.3065) | Closed-network normalizers |
| P30 Kressner-Macedo tensors | [Institutional PDF](https://www.epfl.ch/labs/mathicse/wp-content/uploads/2018/10/17.2014_DK-FM.pdf) | Structured stationary linear algebra |
| P31 Henderson-Glynn | [Author PDF](https://web.stanford.edu/~glynn/papers/2002/HendersonG02.pdf) | Martingale simulation controls |
| P32 dynamic importance sampling | [arXiv](https://arxiv.org/abs/0710.4389) | Queue rare events |
| P33 Cerou-Guyader splitting | [Publisher record](https://www.tandfonline.com/doi/abs/10.1080/07362990601139628) | Splitting; PDF unavailable |
| P34 Burman-Gershwin | [Author PDF](https://web.mit.edu/manuf-sys/www/oldcell1/papers/burman-gershwin-97.pdf) | Unreliable continuous-flow decomposition |
| P35 Colledani-Gershwin | [Author PDF](https://web.mit.edu/manuf-sys/www/oldcell1/papers/colledani-gershwin-anor-2011.pdf) | General Markovian machines / B05 |
| P36 Dai-Wang | [Author PDF](https://people.orie.cornell.edu/jdai/publications/daiWang93.pdf) | Counterexamples to Brownian model validity |
| P37 Dai fluid stability | [Author PDF](https://people.orie.cornell.edu/jdai/publications/dai95a.pdf) | Policy-sensitive stability background |
| P38 Maglaras-Zeevi | [Author PDF](https://business.columbia.edu/sites/default/files-efs/pubfiles/1286/MaglarasZeevi_DiffusionApproximations.pdf) | Priority many-server diffusion |
| P39 Glynn-Zeevi | [Author PDF](https://web.stanford.edu/~glynn/papers/2008/GZeevi08.pdf) | Stationary expectation inequalities |
| P40 stationary characterization | [arXiv](https://arxiv.org/abs/1204.4969) | Reflected-domain probability-measure conditions |
| P41 Blanchet-Chen perfect GJN | [Author PDF](https://web.stanford.edu/~jblanche/papers/Perfect_GJN.pdf) | Dominated coupling from the past |
| P42 Gershwin-Werner | [Author PDF](https://web.mit.edu/manuf-sys/www/oldcell1/papers/gershwin-werner-FINAL-05.pdf) | Closed loops and pallets |
| P43 Bean-Nguyen-Poloni | [arXiv](https://arxiv.org/abs/1801.05981) | Fluid doubling |
| P44 Qu-Blanchet-Glynn | [arXiv](https://arxiv.org/abs/2508.16737) | Learned Lyapunov/Poisson methods |
| P45 priority polling | [arXiv](https://arxiv.org/abs/1408.0282) | Waiting transforms with priorities |
| P46 Abate-Whitt unified inversion | [Author PDF](https://www.columbia.edu/~ww2040/UnifiedDraft.pdf) | Precision and inversion framework |
| P47 Asmussen-Nerman-Olsson | [University copy](https://compbio.fmph.uniba.sk/vyuka/gm/old/2010-02/handouts/Asmussen1996.pdf) | PH EM fitting |
| P48 Dallery-Gershwin | [DOI](https://doi.org/10.1007/BF01158636) | Manufacturing review; PDF unavailable |
| P49 Adan dissertation | [University record](https://research.tue.nl/en/publications/a-compensation-approach-for-queueing-problems-2) | Compensation; PDF unavailable |
| P50 Schwerer LP | [DOI](https://doi.org/10.1081/STM-100002277) | Moment LP; PDF unavailable |
| P51 Reiser-Lavenberg MVA | [IBM record](https://research.ibm.com/publications/mean-value-analysis-of-closed-multichain-queuing-networks) | Exact MVA; PDF unavailable |
| P52 two-moment limitations | [Author PDF](https://people.orie.cornell.edu/jdai/publications/guptaHarcholBalterDaiZwart10.pdf) | Distribution-shape uncertainty |
| P53 Perros blocking survey | [University record](https://repository.lib.ncsu.edu/items/0c11624e-f1d1-4549-b114-32d8794c9cd2) | Blocking taxonomy; PDF unavailable |
| P54 BuTools 2 | [Conference record](https://eudl.eu/doi/10.4108/eai.25-10-2016.2266400) | PH/MAP/block-chain tooling; PDF unavailable |
| Chandy-Neuse Linearizer | [Caltech record](https://authors.library.caltech.edu/records/ewa81-51v69) | A12 full-text acquisition lead |
| Adan-Wessels-Zijm compensation | [Primary record](https://research.tue.nl/en/publications/a-compensation-approach-for-two-dimensional-markov-processes) | A28 full derivation lead |
| NN4MGF author implementation | [Repository](https://github.com/zhangz73/NN4MGF) | A29 reconciliation; pin commit/license before reuse |
| Harrison benchmark author test | [Source file](https://github.com/zhangz73/NN4MGF/blob/main/test_2d_harrison.py) | Independent confirmation of r^(-1/2) exponent |
| Paper-style network implementation | [Source file](https://github.com/zhangz73/NN4MGF/blob/main/fit_mgf.py) | Recheck additive aggregation and conventions at pinned revision |
| PyTorch requirements | [Official installation documentation](https://pytorch.org/get-started/locally/) | Recheck interpreter/device support and select compatible locked versions |
| CVXPY installation and solver capabilities | [Official installation](https://www.cvxpy.org/install/index.html), [solver feature matrix](https://www.cvxpy.org/tutorial/solvers/index.html) | Check current Python/NumPy/SciPy requirements and actual PSD-cone support; do not assume every installed solver handles SDP |
| mpmath inverse Laplace | [Official documentation](https://mpmath.org/doc/current/calculus/inverselaplace.html) | Inversion families, precision, domain limitations |

## 13. Planning completion record

This file is a prospective build-and-test specification. During preparation, the project documentation and relevant interface declarations were inspected read-only; paper equations/tables were extracted and principal benchmark pages visually checked; simple analytic/quadrature oracles were independently evaluated. This planning task did not change any Qnet solver, GUI, build script, test source, dependency configuration, version, binary or app bundle, and did not perform any build/training run. Its only project-file change is this Plans.md. The proposed tests and acceptance checklist are **not yet executed implementation tests**.

Concurrent-work observation, 2026-09-04: the final source-tree comparison detected changes outside this planning task in Sources/Qnet/DesignSystem.swift (modification time 22:42:40 America/New_York) and Sources/Qnet/NetworkEditorModel.swift (22:43:01). These files were neither edited nor reverted by this task. Consequently, the project-wide source tree cannot be described as unchanged during the planning interval; future implementers must recheck the live interfaces before applying this plan.

Future changes to this plan should preserve stable A/H/E/B IDs and append a dated decision record when changing a model scope, formula, expected value, tolerance or source version. Scientific discrepancies should remain visible so a new agent does not repeat a previously resolved mistake.
