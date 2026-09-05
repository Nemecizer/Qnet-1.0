# Qnet: a research roadmap for robust steady-state network analysis

Literature survey and implementation recommendations | 4 September 2026

## Executive recommendation

Qnet should become a portfolio of explicitly scoped solvers, rather than seek one universal approximation. The largest practical gains will come from expanding the models that existing numerical engines can accept, adding independent reference solutions, and reporting the kind of uncertainty attached to every answer.

My recommended first projects are:

1. **Priority re-entrant networks:** implement the workload-to-RBM construction of Dai, Yeh and Zhou, initially for preemptive FBFS and LBFS disciplines.
2. **Two-dimensional RBM transforms:** implement the Franceschi-Raschel boundary-value formulation, with numerical inversion and exact special-case checks.
3. **Closed product-form networks:** add MVA and normalization-constant recursions instead of relying on state enumeration.
4. **Transfer lines:** add exact two-machine building blocks, then blocking-aware decomposition with unreliable machines.
5. **PH/MAP queue models:** expose substantially more of the matrix-analytic machinery through automatic, documented model transformations.
6. **BAR bounds:** develop verified moment/dual bounds, not just another point estimate from a BAR residual.
7. **Priority OU demonstration:** build the two-class many-server example described below as a distinct model family.
8. **Experimental track:** investigate Dai-Zhang neural Laplace-BAR methods, higher-order diffusions, and hybrid solvers only after independent benchmarks exist.

These are recommendations, not changes to Qnet's algorithms or GUI. The survey adds research documents and paper PDFs only.

There are **32 literature-backed candidate projects** below, followed by **six proposed combinations of methods**. Effort and suitability ratings are my engineering judgments, not published runtime or accuracy guarantees. Paper identifiers P01-P54 refer to the accompanying `Paper_Index.md` and provenance manifest; unavailable downloads are explicitly identified there.

## 1. Scope, evidence, and what Qnet already has

This is a broad, implementation-oriented survey, not a claim to cover every queueing paper or to have independently proved every cited theorem. Searches followed primary author publication lists, journal pages, university repositories, arXiv, and references within the most relevant papers. The main threads were Dai's priority/BAR work; numerical stationary RBM; transform inversion and kernel methods; structured Markov chains; closed networks; blocking and manufacturing; and statistically reliable simulation. Recent results were checked through the survey date. Preprints remain labeled as such when the downloaded version is a preprint.

The most relevant model definitions, assumptions, numerical formulations, and limitations were inspected in the full papers. Scanned pages and important equations/tables were visually checked, including the closed-network QNET model, priority OU drift, two-dimensional transform equation, and neural-method moment results. This is not an independent reproduction of their numerical experiments.

The baseline is Qnet 0.90.34's existing `docs/STEADY_STATE_METHODS.md` and the earlier research report, not a review of algorithm implementation effectiveness. That catalog already documents QNA/RQNA, SBD, DES, several SRBM solvers, restricted exact CTMC/QBD/product-form adapters, regenerative simulation, moment LP/SDP, and low-rank BAR experiments. Therefore, several recommendations below are **extensions**, not discoveries of methods absent from the repository.

| Existing capability | Valuable next step, rather than duplication |
|---|---|
| General block-QBD backend; narrow GUI adapter | PH/MAP and reliability model compilers; additional block structures |
| Closed BCMP through enumeration; limited visual exposure | MVA, convolution/MoM, closed-model editor and result mapping |
| Spectral/FEM/grid-LP SRBM solvers | Adaptive bases, full domain geometry, boundary-rate outputs, independent error checks |
| Moment LP/SDP and low-rank BAR prototypes | Stronger realizability constraints, certified dual bounds, broader supported geometries |
| Multiscale SRBM approximation | Separate direct queue-BAR multiscale mapping and priority-specific state-space collapse |
| Finite loss CTMC and blocking approximations | Exact blocked-server states and transfer-line-specific building blocks |
| Simulation, regeneration and narrow rare-event support | Priority/closed-model reference simulation, Poisson controls, general rare-event estimators |

### Four distinctions that should govern the project

**Solving a diffusion is not solving the original queue exactly.** Numerical error, queue-to-diffusion error, truncation/representation error, and statistical error should have separate labels. Agreement between three solvers of the same diffusion does not measure the error of that diffusion approximation.

**A general distribution contains more information than two moments.** Gupta, Harchol-Balter, Dai and Zwart demonstrate a fundamental limitation of universal two-moment approximations even for M/G/K. Qnet should accept distributional/trace inputs where useful and show sensitivity to distribution shape. No numerical sophistication can recover information the model never received. [P52](https://people.orie.cornell.edu/jdai/publications/guptaHarcholBalterDaiZwart10.pdf)

**A finite buffer is a behavioral rule, not just a number.** Loss on full, blocking before service, blocking after service, reservation, overflow routing and manufacturing blocking describe different processes. Buffer capacity must specify whether service positions count. A blocked completed job may occupy a server and prevent new service.

**Priority stability requires more than checking station loads.** In multiclass re-entrant networks, scheduling can create instability despite nominal loads below one. Fluid-model conditions are important, and a valid Brownian approximation is not automatic. Dai's fluid-stability work and Dai-Wang's counterexamples are safeguards for model admission, not alternative numerical solvers. [P37](https://people.orie.cornell.edu/jdai/publications/dai95a.pdf), [P36](https://people.orie.cornell.edu/jdai/publications/daiWang93.pdf)

## 2. Jim Dai, priorities, and Ornstein-Uhlenbeck processes

There are three distinct research lines here. They should not be merged under a single “priority diffusion” menu item.

### 2.1 Conventional heavy traffic: priority re-entrant lines

Dai, Yeh and Zhou's 1997 QNET paper is the most direct starting point for Qnet's current domain. It treats re-entrant lines with deterministic stage routes, single-server stations and preemptive first-buffer-first-served or last-buffer-first-served priorities. It constructs a station-dimensional workload RBM, computes its stationary law, and estimates workloads and network sojourn time. It also develops a refined FBFS sojourn approximation. It does not provide a universal stationary joint distribution for all class queues or arbitrary priorities. [P04](https://people.orie.cornell.edu/jdai/publications/daiYehZhou97.pdf)

**My recommendation:** reproduce one small two-station example and then a multi-stage re-entrant line. Use existing SRBM backends after introducing a priority-specific workload mapping. Preserve class/stage identities and distinguish preemptive-resume from nonpreemptive service. This is a better first priority-network extension than fitting an OU process to an arbitrary FCFS network.

### 2.2 Direct steady-state BAR limits for priority networks

Braverman, Dai and Miyazawa develop a BAR approach for static-buffer-priority networks, with stability, state-space collapse and a tight-matrix condition as separate requirements. This works directly with stationary equations and Palm distributions rather than relying only on a process-limit/interchange argument. [P11](https://arxiv.org/abs/2302.05791)

Dai and Huo obtain product-form exponential limits in **multiscale** heavy traffic, subject to moment and structural conditions. Their two-station, five-class case study is especially useful for an implementation benchmark. High-priority components that vanish on a heavy-traffic scale are not literally zero in the original queue. Approximation of their finite-load delays needs additional work. [P12](https://arxiv.org/abs/2403.04090), [P13](https://arxiv.org/abs/2411.00930), [P15](https://arxiv.org/abs/2404.13651)

For the case-study policy prioritizing stages `(5,3,1)` at station 1 and `(2,4)` at station 2, the paper identifies the extra virtual-station load involving stages 2 and 5. This is an excellent test that the analyzer checks more than the two physical station loads. My proposed admission checks should initially recognize proved subclasses, with unsupported cases clearly marked; there is no universal finite-data test that proves a whole asymptotic regime.

### 2.3 Many-server heavy traffic: a concrete priority OU model

The closest match to the requested OU idea is the Maglaras-Zeevi differentiated-service model and the two-class many-server illustration in Sauré-Glynn-Zeevi's BAR-LP draft. The former develops a multidimensional diffusion and a perturbation approximation; the latter numerically solves a related stationary diffusion through a BAR LP. [P38](https://business.columbia.edu/sites/default/files-efs/pubfiles/1286/MaglarasZeevi_DiffusionApproximations.pdf), [P24, Section 6](https://www.dii.uchile.cl/~dsaure/papers/LP_SRBM.pdf)

In the two-class illustration, with capacity proportions κ₁+κ₂=1 and arrival scaling λᵢ⁽ⁿ⁾=nκᵢμᵢ−√nγᵢμᵢ, the centered class counts have diffusion drift

\[
b_1(x)=-\mu_1(\gamma_1+x_1),\qquad
b_2(x)=\begin{cases}
-\mu_2(\gamma_2+x_2),&x_1+x_2\le0,\\
-\mu_2\gamma_2+\mu_2x_1,&x_1+x_2>0.
\end{cases}
\]

The covariance is `diag(2μ₁κ₁, 2μ₂κ₂)`. The high-priority component is OU, with stationary marginal `Normal(−γ₁, κ₁)`. The joint law is not generally Gaussian. The diffusion's stability condition is γ₁+γ₂>0; the LP draft uses a stronger condition for its illustrative Lyapunov construction. Its centered state lives in **R²**, not the nonnegative orthant, and its stationary equation has no reflection-face terms. The downloaded P24 is an author-posted preliminary draft marked “not for distribution”; retain it for private research rather than bundling it with a public Qnet release.

**My recommendation:** implement this as an explicitly named many-server priority model, with stationary density, class counts, low-priority congestion and the exact high-priority marginal as a built-in check. Compare against a discrete model with matching allocation and preemption rules. Do not assume that a valid diffusion stationary law alone proves steady-state convergence of every corresponding queue sequence.

Dai-He's numerical many-server work is another strong implementation source, but its main queue is FIFO GI/Ph/n+GI, with phase-type service and abandonment. It uses reference-density projection/FEM and considers different abandonment approximations. It is not a generic priority-network theorem. Dai-Dieker-Gao separately establish steady-state validity for their stated many-server abandonment setting. [P07](https://arxiv.org/abs/1104.0347), [P09](https://arxiv.org/abs/1306.5346)

## 3. BAR as a family of computational formulations

### 3.1 A common mathematical interface

For an orthant SRBM, write

\[
dZ(t)=\mu\,dt+\sigma\,dW(t)+\sum_i r_i\,dY_i(t),\qquad \Sigma=\sigma\sigma^T.
\]

Here `rᵢ` is a reflection column, and `Yᵢ` increases only on face `zᵢ=0`. With stationary interior probability measure π and boundary measures

\[
\nu_i(A)=E_\pi\!\left[\int_0^1 1_{\{Z(t)\in A\}}\,dY_i(t)\right],
\]

the BAR is

\[
\int\left(\mu\cdot\nabla f+\tfrac12\Sigma:\nabla^2 f\right)d\pi
+\sum_i\int r_i\cdot\nabla f\,d\nu_i=0.
\]

This is the shared object behind density projection, moment optimization, transform equations and boundary-measure computation. Boundary measures are **not probability measures**: their masses are regulator rates and depend on reflection normalization. With the required integrability, linear tests give `μ+Rβ=0`, where `βᵢ=νᵢ(face i)`. Probability normalization is `π(1)=1`. [P19, including Appendix D](https://arxiv.org/abs/1312.1758)

My architectural suggestion is to represent the domain, generator, reflection fields, interior measure and each boundary measure explicitly. Every numerical method can then report the same independent balance tests. For a box, both upper and lower faces are needed; for a closed-network simplex, the population constraint changes the geometry. The BAR generalizes by summing over the actual faces, not by reusing orthant faces under different labels.

For ordinary nondegenerate SRBM, the stationary probability of lying exactly on a face is zero although its regulator rate can be positive. Consequently, a Brownian upper-face regulator is not directly a discrete full-buffer probability or a lost-customer fraction. A queue-specific scaling/flow relationship is needed.

### 3.2 The computational choices

| BAR use | Numerical unknown | Best role in Qnet | Main caution |
|---|---|---|---|
| Reference-density Galerkin | Density ratio coefficients | Whole stationary law in modest dimension | Basis growth, conditioning and tail-compatible reference density |
| Local FEM / weak stationary PDE | Local density coefficients | Boxes, simplexes, boundary layers | Mesh dimension and correct oblique boundary treatment |
| Grid occupation-measure LP | Nonnegative masses for interior and faces | Flexible stationary approximations | Grid feasibility alone is not a rigorous bound |
| Moment LP/SDP | Interior and face moments | Bounds on means, correlations, polynomial costs | Moment existence, realizability, degree growth |
| Dual Poisson/Lyapunov inequalities | Test function and cost bound | Certified interval for a requested metric | Must validate inequalities globally, including tails and faces |
| Laplace/kernel BAR | Interior and face transforms | 2D distribution/tail solver | Unknown boundary transforms do not disappear automatically |
| Product-form / decomposition tests | Algebraic parameter relations | Exact RBM shortcuts and benchmarks | Exact independence conditions are restrictive |
| Neural transform BAR | Transform approximators | Experimental high-dimensional observables | Positivity, analytic consistency, inversion and external validation |
| Direct queue BAR asymptotics | Scaled queue transforms and Palm terms | Fast heavy-traffic approximations | A limit theorem is not a finite-load exact solution |
| BAR/Poisson control variates | Approximate value/Poisson function | Reduce simulation cost | Control must use the actual simulated process |

### 3.3 A particularly useful dual-bound construction

Here is a concrete way to make BAR useful without reconstructing the full distribution. This algebraic construction follows the drift-inequality principle of Glynn-Zeevi. Suppose the target is π(g), and an admissible function h satisfies

\[
g+\mathcal Lh\le U\quad\hbox{throughout the interior},\qquad
r_i\cdot\nabla h\le0\quad\hbox{on every face}.
\]

Integrating and using the BAR yields

\[
\pi(g)\le U-\pi(\mathcal Lh)
=U+\sum_i\nu_i(r_i\cdot\nabla h)\le U.
\]

Reversing both inequalities produces a lower bound. Polynomial h permits SOS/SDP relaxations on suitable domains; piecewise or numerically fitted h can be candidates for a separate rigorous verifier. Upper and lower objective values would give a useful stopping criterion. Existence/integrability assumptions, global inequality validation and numerical rounding matter: a sampled inequality or solver status is not a certificate. [P39](https://web.stanford.edu/~glynn/papers/2008/GZeevi08.pdf)

This is one of my highest-value medium-term projects. It can be started with 1D/2D examples and extended independently of the chosen point-estimate method.

### 3.4 Positivity and characterization are substantive issues

Dai-Dieker's 2011 paper **states and analyzes an open problem** about sign-changing solutions; its title should not be mistaken for a general theorem that every signed BAR solution is nonnegative. Kang-Ramanan provide stationary characterizations for probability measures under their domain/test-function assumptions. Neither observation makes an arbitrary finite numerical solution a probability law. [P10](https://people.orie.cornell.edu/jdai/publications/DaiDieker2011.pdf), [P40](https://arxiv.org/abs/1204.4969)

I recommend enforcing nonnegativity where possible and checking normalization and moment consistency independently. This survey does not claim to settle the current status of all signed-measure uniqueness conjectures.

## 4. Generating functions, Laplace transforms, and inversion

### 4.1 What to transform

For discrete queue counts N, the natural object is the probability generating function

\[
G(z_1,\ldots,z_d)=E\!\left[\prod_i z_i^{N_i}\right].
\]

For nonnegative continuous workloads/RBM, use the Laplace-Stieltjes transform

\[
\phi(s)=E[e^{-s^T Z}].
\]

For a discrete random vector, its LST is already `G(e^(−s₁),…,e^(−s_d))`. Taking another Laplace transform of G as a function is usually not the useful operation. The productive workflow is to transform the balance/BAR equations, solve the resulting functional equation, then extract moments, coefficients or distributions. Abate-Whitt provide numerical inversion machinery for both generating functions and continuous transforms. [P25](https://www.columbia.edu/~ww2040/FourierSeries1992.pdf)

### 4.2 The transformed BAR and its missing information

Substituting `f(z)=exp(−sᵀz)` into the BAR above gives, with the stated convention,

\[
\left(\tfrac12s^T\Sigma s-\mu^Ts\right)\phi(s)
-\sum_i(r_i^Ts)\phi_i(s)=0,
\qquad \phi_i(s)=\int e^{-s^Tz}\nu_i(dz).
\]

The face transform φᵢ does not depend on sᵢ for a lower orthant face. It has normalization `φᵢ(0)=βᵢ`, not one. In a box, an upper-face transform includes the corresponding `exp(−sᵢKᵢ)` factor.

One equation in several unknown functions is not an explicit solution. In two dimensions, the zero set of the quadratic kernel and analytic continuation turn the problem into a boundary-value problem for the face transforms. Franceschi-Raschel give an integral formula using this route. Their revised paper handles the stable two-dimensional cases in its assumptions, including the discussion of a drift with one nonnegative component; checking only “both drift components negative” would unnecessarily restrict the adapter. [P21](https://arxiv.org/abs/1703.09433)

### 4.3 What Qnet can obtain without high-dimensional inversion

My suggested transform API should support:

- **Marginals:** evaluate `φ(seᵢ)` and invert one dimension.
- **Weighted aggregate workload:** evaluate `φ(sa)` for nonnegative weights a. This gives the transform of `aᵀZ`, not a general joint-tail probability.
- **Moments:** differentiate at zero only when the moments exist, with stable derivative/contour methods and a conditioning diagnostic.
- **PGF coefficients:** use Cauchy/Fourier coefficient extraction with radius and aliasing checks.
- **Tail behavior:** use singularity analysis where its hypotheses hold, rather than pretending an asymptotic equivalent is an exact small-threshold probability.

An LST of a nonnegative variable X gives the Laplace transform of its CDF as `φ(s)/s`, and of its survival function as `(1−φ(s))/s`, for positive real part. Direct survival inversion can avoid subtracting a CDF close to one, although transform cancellation near zero still needs attention. A full d-dimensional grid inversion remains expensive even when transform evaluation is cheap.

Implement at least two independent inversion families, such as Fourier/Euler and Talbot, with precision escalation. Talbot contours may need transform evaluation outside the right half-plane, so a real-positive-axis fit alone is insufficient. The contour must stay in a valid analytically continued region. Increasing arithmetic precision does not repair an inaccurate learned transform. [P46](https://www.columbia.edu/~ww2040/UnifiedDraft.pdf)

An end-to-end response-time distribution also needs more than the stationary queue-length vector. Little's law supplies means, not a general distributional identity; tagged-customer or Palm analysis and dependence along a route can matter.

## 5. Detailed candidate list

Ratings: **Near** = good next implementation; **Next** = worthwhile after its prerequisites; **Research** = prototype and validate before offering as a routine result. Effort is relative to the current Qnet base: **M** = substantial integration/mathematical mapping, **H** = new specialist numerical/modeling work, **R** = unresolved generalization or uncertain research outcome. It includes model admission and validation, not only writing the numerical kernel.

### Open generalized Jackson networks and structured Markov models

#### A01. PH/MAP model compilation into matrix-analytic solvers

**Near; extension; effort H.** Fit phase-type service/interarrival distributions and Markovian arrival processes, then generate QBD or related structured chains for supported nodes/subnetworks. PH fitting via EM has a well-established foundation; BuTools describes a useful family of PH/MAP and block-chain computational methods. [P47](https://pure.au.dk/portal/en/publications/fitting-phase-type-distributions-via-the-em-algorithm/), [P54](https://eudl.eu/doi/10.4108/eai.25-10-2016.2266400)

**Advantages:** richer service shape and burst correlation; stationary queue tails as well as means; exact numerical solution of the fitted Markov model. **Disadvantages:** phase explosion; fitting ambiguity; a finite PH distribution does not reproduce a genuine heavy tail asymptotically. Internal network departures need not remain low-order MAPs. **First implementation:** MAP/PH/1 and finite-capacity variants, then small priority/reliability models. Two unrestricted infinite priority queues do not automatically produce a finite-phase QBD; explicitly bounded/truncated phases require their own error accounting.

#### A02. Certified stationary truncation for non-product-form CTMCs

**Near; extension; effort H.** Combine reachable-state expansion with Foster-Lyapunov moment/tail control and stationary LP outer bounds. Kuntz and coauthors distinguish several truncation schemes and their error properties; Infanger-Glynn-Liu study convergence of truncation-augmentation schemes. [P26](https://arxiv.org/abs/1909.05794), [P28](https://arxiv.org/abs/2203.15167)

**Advantages:** an independent reference solution for moderate PH/priority models; potentially provable probability intervals. **Disadvantages:** state growth and difficult Lyapunov bounds; a convergent sequence does not automatically provide a computable finite-run error bound. **First implementation:** one non-product-form two-node CTMC with an explicit drift certificate, then report retained-state probability intervals and escaped mass. Do not call the current small-boundary-mass heuristic a certificate of interior bias.

#### A03. Direct GJN multiscale product-form approximation

**Next; extension; effort M.** Implement the original queue-parameter mapping of Dai-Glynn-Xu separately from any existing multiscale SRBM formula. The downloaded v3 is revised in 2025. It describes widely separated heavy-traffic normalization factors and effective single-station parameters. [P14](https://arxiv.org/abs/2304.01499)

**Advantages:** very fast approximate distributions in the intended regime; plausible warm starts and screening estimates. **Disadvantages:** asymptotic independence is not exact finite-load independence, particularly for similarly loaded interacting bottlenecks. **First implementation:** measure load separation, preserve the effective-variance construction, and compare separated versus nearly equal bottleneck loads. Never advertise a selected load-ratio threshold as a theorem proving accuracy.

#### A04. Higher-order, state-dependent diffusion approximations

**Research; new model approximation; effort R.** Braverman-Dai-Fang use higher-order generator expansions and Stein/Poisson equations, demonstrating their approach for Erlang-C, a hospital model and an autoregressive model. [P17](https://arxiv.org/abs/2012.02824)

**Advantages:** targets queue-to-diffusion error rather than merely solving the old diffusion more accurately; useful away from the strict asymptotic limit. **Disadvantages:** the paper is not a turnkey high-dimensional GJN formula; preserving a valid nonnegative diffusion coefficient and suitable boundary behavior requires care. **First implementation:** reproduce the one-dimensional Erlang-C approximation; only then derive a two-node or priority extension. Compare both against the exact queue, not only against conventional RBM.

#### A05. Tensor-structured stationary Markov solvers

**Next; extension; effort H.** Represent local transitions and selected interactions in tensor/Kronecker form and solve the stationary system with low-rank tensors. Kressner-Macedo study communicating Markov processes using this structure. [P30](https://www.epfl.ch/labs/mathicse/wp-content/uploads/2018/10/17.2014_DK-FM.pdf)

**Advantages:** potentially much lower memory than explicit full-state storage; attractive for modular unreliable-machine or PH models. **Disadvantages:** strong feedback and blocking can increase ranks sharply; low-rank truncation may damage positivity; no universal low-rank guarantee. **First implementation:** a finite line with local interactions, where sparse CTMC solutions still permit checking rank/error tradeoffs. Distinguish this stationary-CTMC tensor method from Qnet's existing low-rank exponential BAR ansatz.

### Finite buffers and transfer lines

#### A06. Exact two-machine/one-buffer models with reliability

**Near; new model family; effort M-H.** Generate the small Markov model with buffer contents, machine up/down or failure-mode states and the selected blocked-server semantics. These exact submodels are the foundation of the manufacturing decomposition literature. [Gershwin's primary publication catalog](https://web.mit.edu/manuf-sys/www/oldcell1/gershwin.pubs.transferlines.html)

**Advantages:** throughput, starvation, blocking and inventory reference values; reusable local building blocks. **Disadvantages:** exponential/phase-type or discrete-cycle assumptions are needed for finite Markov formulations; “failed while idle” and “failed while working” differ. **First implementation:** two unreliable exponential machines with BAS; add synchronous Bernoulli-cycle models as a separately named family. Test failure-free and infinite-buffer limits plus small exact enumeration.

#### A07. Transfer-line decomposition with blocking/starvation feedback

**Near; new specialized decomposition; effort H.** Solve coupled two-machine approximations, adjusting effective upstream/downstream behavior to maintain flow relations. Burman-Gershwin and Colledani-Gershwin provide concrete algorithms; the latter admits general Markovian machine states. [P34](https://web.mit.edu/manuf-sys/www/oldcell1/papers/burman-gershwin-97.pdf), [P35](https://web.mit.edu/manuf-sys/www/oldcell1/papers/colledani-gershwin-anor-2011.pdf)

**Advantages:** high practical value for long transfer lines, unequal speeds and finite inventories; much cheaper than whole-line enumeration. **Disadvantages:** long-range dependence is approximated; parameter matching and convergence can be delicate near severe blocking. **First implementation:** a five-machine line with asymmetric buffers and failure rates. Return throughput, buffer profiles and machine state fractions, not only mean queues. Compare adjacent bottlenecks with well-separated ones.

#### A08. Markov-modulated fluid buffers and Riccati/doubling methods

**Near/Next; new model family; effort H.** Model net material rates driven by a finite-state machine/environment chain. Use matrix-analytic return-probability equations and doubling methods, with finite-buffer boundary equations when appropriate. Bean-Nguyen-Poloni explain the Riccati and QBD connections; their core regulated-fluid formulation has a lower boundary, so upper-capacity handling is an additional formulation. [P43](https://arxiv.org/abs/1801.05981)

**Advantages:** natural for long machine up/down periods relative to processing cycles; handles multiple production speeds; stationary level distributions and boundary atoms are available in fluid models. **Disadvantages:** fluid inventories are not discrete jobs; tiny buffers and cycle synchronization can violate the approximation. **First implementation:** two-state Markov-modulated fluid buffer, then connect to A07's finite manufacturing blocks. Unlike ordinary nondegenerate RBM, fluid models can have stationary boundary atoms.

#### A09. Full bounded-domain BAR for finite networks

**Near; extension; effort H.** Use the existing FEM lineage, adding consistently represented upper/lower faces and requested boundary-flow outputs; consider an independent bounded-domain LP formulation. Dai-Harrison's rectangle method and Shen-Chen-Dai-Dai's hypercube FEM are directly relevant. [P01](https://people.orie.cornell.edu/jdai/publications/daiHarrison91.pdf), [P05](https://people.orie.cornell.edu/jdai/publications/shenChenDaiDai02.pdf)

**Advantages:** whole stationary diffusion distributions; explicit finite-buffer geometry; local refinement near boundaries. **Disadvantages:** exponential mesh growth; an incorrect reflection map solves the wrong queue approximation very accurately. Dai-Dai's finite-buffer limit is specifically single-class, single-server, deterministic feedforward routing with block-and-hold-0 and heavy-traffic buffer scaling; it is not a theorem for every BAS/loss network. [P06](https://people.orie.cornell.edu/jdai/publications/daiDai99.pdf)

**First implementation:** reproduce a supported finite tandem, making the blocking/scaling contract visible. Keep arbitrary-topology mappings experimental until justified.

### Closed networks

#### A10. Exact mean-value analysis and convolution

**Near; extension; effort M.** Add population-recursive MVA and stable normalization-constant computation for supported closed BCMP subclasses. Reiser-Lavenberg's MVA computes mean performance without enumerating all network states. [P51](https://research.ibm.com/publications/mean-value-analysis-of-closed-multichain-queuing-networks)

**Advantages:** mature exact queue-model means under product-form assumptions; immediately removes an important enumeration bottleneck. **Disadvantages:** multiclass population-vector recursion can still be expensive; basic MVA does not return the full joint distribution; arbitrary FCFS class-dependent service, priorities and blocking destroy its justification. **First implementation:** one-class closed network with delay and single-server centers, followed by multiclass PS/IS examples. Use enumeration only as a small-case oracle. For tails, add normalizer/marginal recursions rather than labeling mean-only MVA a distribution solver.

#### A11. Multi-branched Method of Moments / RECAL-type normalizers

**Next; extension; effort H.** Use recurrences for normalizing constants and higher queue moments in closed multiclass product-form networks. Casale's multi-branched MoM integrates recursive information from models with different numbers of queues. This is a different “method of moments” from BAR moment-SDP optimization. [P29](https://arxiv.org/abs/0902.3065)

**Advantages:** exact product-form performance for cases where population-enumerating recursions are costly; access to distributional measures through normalizers. **Disadvantages:** matrix recurrence size, conditioning and precision management; performance depends on number of classes and centers. **First implementation:** select between MVA, convolution and MoM using estimated storage/operation counts, then validate normalizer ratios and class throughput against exact small cases.

#### A12. Approximate MVA / linearizer family

**Next; extension; effort M.** Use approximate population-removal relations and fixed-point updates when exact multiclass recursion is too large. The original MVA paper motivates heuristic extensions; Chandy-Neuse's Linearizer specifically addresses large closed product-form networks with single-server and delay centers. [P51](https://research.ibm.com/publications/mean-value-analysis-of-closed-multichain-queuing-networks), [Chandy-Neuse 1982](https://authors.library.caltech.edu/records/ewa81-51v69)

**Advantages:** inexpensive population/bottleneck sweeps; practical for large class counts. **Disadvantages:** convergence does not certify accuracy, and mean-based closures do not identify a joint stationary law. General-service or blocking corrections introduce an additional approximation layer. **First implementation:** a clearly labeled approximation for the same BCMP contracts as A10, with exact-MVA comparisons before expanding beyond product form. This is lower priority than implementing exact MVA itself.

#### A13. Closed-network Brownian QNET on a simplex

**Next; new queue-to-diffusion mapping; effort H.** Dai-Harrison's 1993 closed manufacturing QNET paper reduces the Brownian model to RBM in a simplex. Its stated model includes a common service-time distribution across classes at each station. [P03](https://people.orie.cornell.edu/jdai/publications/daiHarrison93.pdf)

**Advantages:** introduces second-moment sensitivity beyond insensitive product-form models; connects directly to Qnet's Brownian strengths. **Disadvantages:** population conservation creates dependence and changes the state space; the published assumptions do not allow arbitrary class-dependent service or dispatching. **First implementation:** the paper's symmetric cyclic example and a small multiproduct manufacturing model. Enforce population conservation in coordinates, then compare throughput and cycle-time predictions with closed DES. An open orthant solver with zero external arrivals is not a closed-network solver.

#### A14. Closed-loop blocking and CONWIP/pallet decomposition

**Next; new model family; effort H.** Gershwin-Werner extend line decomposition to closed loops with unreliable machines and limited inventories, including pallet/token interpretations. [P42](https://web.mit.edu/manuf-sys/www/oldcell1/papers/gershwin-werner-FINAL-05.pdf)

**Advantages:** particularly useful bridge between transfer lines and closed networks; predicts production and inventory versus WIP limits. **Disadvantages:** a fixed population does not guarantee a useful non-deadlocked operating regime; loop dependencies complicate decomposition; a pallet loop is not automatically a BCMP network. **First implementation:** a three-machine loop and then a longer CONWIP line. Specify release, token return and transport behavior; detect deadlock/reducibility before reporting a single “steady state.”

### Priority, many-server and special-service systems

#### A15. FBFS/LBFS priority workload RBM

**Near; new mapping, reuse SRBM backend; effort H.** Implement the route/station/priority transformation described in Section 2.1. **Advantages:** strong alignment with re-entrant manufacturing and existing Brownian numerics; exposes discipline-dependent congestion. **Disadvantages:** class reconstruction and finite-load accuracy need separate validation; nonpreemptive results should not be silently inferred from a preemptive model. **First implementation:** supported two-station line with FBFS versus LBFS, workload and network mean sojourn as primary outputs; defer full class delay distributions. Source: [P04](https://people.orie.cornell.edu/jdai/publications/daiYehZhou97.pdf).

#### A16. SBP multiscale stationary approximations

**Next; extension; effort H.** Implement the direct queue-BAR limit for a proved priority subclass, beginning with the Dai-Huo case study. **Advantages:** extremely cheap approximate congestion for separated bottlenecks; useful comparison to A15. **Disadvantages:** requires asymptotic and moment conditions; ordinary station utilization checks are insufficient; high-priority delay estimates need more than the limiting collapsed coordinates. **First implementation:** reproduce the exact case-study policy and parameters, then vary the scale separation. Sources: [P11](https://arxiv.org/abs/2302.05791), [P12](https://arxiv.org/abs/2403.04090), [P13](https://arxiv.org/abs/2411.00930).

#### A17. Two-class priority piecewise-OU stationary solver

**Near as a bounded demonstration; new model family; effort M-H.** Implement Section 2.3 with nonnegative grid-LP masses or a density PDE solver on an expanding domain. **Advantages:** directly answers the OU interest; exact first-coordinate Gaussian check; approachable 2D joint-density example. **Disadvantages:** many-server scaling and centered coordinates differ from ordinary GJN workloads; drift switches across a line; truncation and discrete-model bias remain. **First implementation:** one published parameter set, then service-rate and load imbalance sweeps. The benchmark and model assumptions are more important than adding a generic “OU” button. Sources: [P38](https://doi.org/10.1287/moor.1040.0090), [P24](https://www.dii.uchile.cl/~dsaure/papers/LP_SRBM.pdf).

#### A18. PH many-server queues with abandonment

**Next; new model family; effort H.** Adapt Dai-He reference-density numerics for FIFO GI/Ph/n+GI; start with exponential patience before general hazards. **Advantages:** non-exponential service shape, delay probabilities and abandonment-sensitive congestion; useful overloaded systems can be stable with abandonment. **Disadvantages:** extra phase dimensions; tail/reference-density selection and patience approximation matter; cannot label every overloaded model stable merely because an abandonment field exists. **First implementation:** M/H₂/n+M and an Erlang-A exact comparison. Separate numerical, approximation and steady-state-limit evidence. Sources: [P07](https://arxiv.org/abs/1104.0347), [P09](https://arxiv.org/abs/1306.5346).

#### A19. Skill-based N-system policy evaluation

**Later; adjacent model family; effort H.** Evaluate fixed routing/priority policies in a two-class, two-pool many-server N-system. Tezcan-Dai's optimality result assumes pool-dependent but class-independent service speeds and includes holding/reneging costs; its objective is finite-horizon, so it is not a universal stationary optimality theorem. [P08](https://people.orie.cornell.edu/jdai/publications/tezcanDai10.pdf)

**Advantages:** expands Qnet toward staffing/resource pooling and scheduling comparisons. **Disadvantages:** resource compatibility and control decisions are beyond fixed-routing Jackson networks; optimal control is a separate undertaking. **First implementation:** fixed-policy DES and its diffusion evaluation, with no claim of globally optimal stationary priority selection.

#### A20. Priority polling and vacation systems via transforms

**Next; new special-network family; effort H.** Boon-Adan-Boxma derive transforms for cyclic polling with multiple priority levels and gated, exhaustive or globally gated service. [P45](https://arxiv.org/abs/1408.0282)

**Advantages:** class-specific waiting distributions, switch-over delays and shared roaming servers; a concrete non-RBM transform application. **Disadvantages:** branching/service-discipline assumptions are specific; arbitrary limited service, finite buffers, feedback or changeovers need new derivations. **First implementation:** two queues, two priorities in one queue, explicit switch-over distribution. Preserve the distinction between polling-epoch and arbitrary-time queue distributions. Potential applications include shared operators, inspection and setup-heavy workcenters, not just communication systems.

### Stationary RBM and transform computation

#### A21. Exact RBM structure detection beyond product form

**Near; extension; effort M.** Add decomposability tests and selected two-dimensional sum-of-exponentials/closed-form cases to the existing skew-symmetry check. Dai-Miyazawa-Wu study independent blocks; Dieker-Moriarty characterize finite exponential sums in a wedge; Bousquet-Melou and coauthors classify special transform forms. [P20](https://arxiv.org/abs/1312.1387), [P23](https://arxiv.org/abs/0712.0844), [P22](https://arxiv.org/abs/2101.01562)

**Advantages:** fast exact answers for the RBM and valuable test cases. **Disadvantages:** stringent algebraic/geometric conditions; near-equality does not imply exact factorization; exponential-sum coefficients need not all be positive even when the density is. **First implementation:** add a non-product-form 2D benchmark and a certified independent-block reduction. Treat “nearly decomposable” as a different approximation.

#### A22. Adaptive reference-density spectral/Galerkin methods

**Next; extension, not replacement; effort H.** Improve the approximation space using anisotropic degrees, orthogonal bases, coordinate scaling, and tail-compatible reference densities, following the Dai-Harrison/Dai-He numerical framework. [P02](https://people.orie.cornell.edu/jdai/publications/daiHarrison92.pdf), [P07](https://arxiv.org/abs/1104.0347)

**Advantages:** reuses existing architecture and can focus resolution on bottleneck directions. **Disadvantages:** basis counts and condition numbers can still grow rapidly; density projection need not preserve positivity; a poor reference tail can invalidate the function-space setup. **First implementation:** adaptive degree selection on 2D/3D cases with density normalization, negativity diagnostics and held-out BAR tests. Any sparse/adaptive design beyond the papers is an engineering extension requiring validation.

#### A23. Adaptive nonnegative occupation-measure BAR LP

**Next; extension; effort H.** Develop interior/face discretizations together and adapt support points and test functions, instead of increasing a full tensor grid uniformly. **Advantages:** flexible geometry and nonnegative discrete measures; direct requested-event approximations. **Disadvantages:** finite-grid solutions are not automatically bounds for the continuous problem; unbounded domains need tightness/tail control; mass can fit a small test set while missing other features. **First implementation:** 2D orthant and box using distinct face masses, with cross-grid and cross-basis refinement. This extends the Sauré-Glynn-Zeevi formulation; adaptive column/test selection is my proposed addition. Source: [P24](https://www.dii.uchile.cl/~dsaure/papers/LP_SRBM.pdf).

#### A24. BAR moment LP/SDP with distributional bounds

**Near/Next; extension; effort H.** Schwerer develops polynomial-test BAR moment LPs. Extend Qnet's moment machinery with valid support/localizing constraints and boundary moments, and investigate polynomial majorants/minorants of requested events. [P50](https://doi.org/10.1081/STM-100002277)

**Advantages:** potentially rigorous intervals for means/correlations without density reconstruction; positivity constraints rule out impossible moment sequences. **Disadvantages:** PSD matrices grow combinatorially; higher moments may not exist; interval interpretation requires a genuine outer relaxation and controlled numerical error. Kuntz and coauthors provide rigorous mathematical-programming methods for CTMC stationary distributions, but their chemical-master-equation results require adaptation rather than automatic transfer to reflected diffusions. [P27](https://arxiv.org/abs/1702.05468)

**First implementation:** verify a 1D finite interval and 2D box; progress to an orthant only with explicit tail/moment assumptions.

#### A25. Dual BAR/Poisson certificates

**Near/Next; new certification layer; effort H.** Implement the metric-specific bounds in Section 3.3. **Advantages:** can certify a requested performance measure without recovering the full law; useful stopping rule and independent check of any point estimator. **Disadvantages:** good admissible test functions are hard to find; pointwise verification is itself an optimization problem; global tails and faces cannot be omitted. **First implementation:** bound mean total workload in 2D using polynomial h, with numerical candidate generation followed by independent inequality checks. Source: [P39](https://web.stanford.edu/~glynn/papers/2008/GZeevi08.pdf).

#### A26. Two-dimensional BAR/kernel boundary-value solver

**Near; new numerical route; effort H.** Implement the Franceschi-Raschel transform formula with careful complex branches and quadrature. **Advantages:** directly accesses the stationary RBM transform without a 2D spatial mesh; useful marginals, aggregate-workload tails and a strong independent benchmark. **Disadvantages:** specialist complex numerics; sensitivity near branch points and degenerate parameters; not an off-the-shelf d-dimensional or finite-rectangle solver. **First implementation:** positive-definite covariance, well-conditioned stable reflection, followed by difficult drift/reflection cases. Compare to exact special cases and independent spatial solvers. Source: [P21](https://arxiv.org/abs/1703.09433).

#### A27. Reusable transform inversion and tail-analysis service

**Near; new shared infrastructure; effort M-H.** Implement the interfaces in Section 4 with precision/refinement checks and more than one inversion family. Add analytic tail diagnostics from the two-dimensional SRBM geometric literature where applicable. [P25](https://www.columbia.edu/~ww2040/FourierSeries1992.pdf), [P46](https://www.columbia.edu/~ww2040/UnifiedDraft.pdf), [P18](https://arxiv.org/abs/1110.1791)

**Advantages:** benefits PH, polling, RBM and exact queue transforms; avoids repeated one-off inversion code. **Disadvantages:** it cannot create an unknown transform or repair a wrong one; very small tail probabilities need careful conditioning and independent checks. **First implementation:** exponential/Erlang/mixture distributions, geometric PGFs, and aggregate sums with known transforms. Return a domain/precision warning instead of silently clipping negative densities or probabilities.

#### A28. Compensation methods for selected two-dimensional chains

**Later; new exact structured route; effort H.** Represent a stationary distribution as a convergent series of product terms that successively correct boundary errors. Adan-Wessels-Zijm establish conditions for this approach for specific two-dimensional Markov random walks. [Primary paper record](https://research.tue.nl/en/publications/a-compensation-approach-for-two-dimensional-markov-processes)

**Advantages:** accurate distributional answers for some non-product-form special networks; complements transform/BVP methods. **Disadvantages:** stringent transition structure; no general extension to arbitrary network dimension or jump rules. **First implementation:** one published shortest-queue/related example, with explicit admissibility checks and series-tail control. The dissertation download was unavailable; this recommendation relies on the primary publication record and its stated scope, not a completed derivation review.

#### A29. Neural Laplace-BAR solver

**Research; new experimental backend; effort R.** Dai-Zhang's July 2026 preprint learns interior and boundary transforms, then inverts them. Its examples include non-product-form 2D RBM and product-form 20D/30D RBMs. The displayed tail comparisons reach approximately 1%, not demonstrated ultra-rare-event accuracy. Appendix B's 30D table contains negative estimated second moments. [P16](https://arxiv.org/abs/2607.08091)

**Advantages:** potentially scalable access to selected high-dimensional workload distributions. **Disadvantages:** heavy training cost, transform validity and inversion sensitivity; the evidence does not establish arbitrary high-dimensional correlated performance. **First implementation:** reproduce published examples, then challenge with non-product-form correlated cases, multiple seeds and independent simulation. Enforce transform/moment consistency and report failures explicitly. It is a promising research project, not a replacement for tested solvers or certified bounds.

### Reliable simulation and hybrid computation

#### A30. Perfect stationary sampling of supported GJNs

**Next; new sampling algorithm; effort H-R.** Blanchet-Chen give dominated-coupling-based perfect sampling for FIFO, single-server, infinite-buffer GJNs under their stability, light-tail and interarrival-support assumptions. [P41](https://web.stanford.edu/~jblanche/papers/Perfect_GJN.pdf)

**Advantages:** removes initialization bias for the supported model; strong reference samples for approximations. **Disadvantages:** random and potentially large coalescence cost near criticality; not a generic solution for priorities, heavy tails, finite blocking or closed networks. “Perfect sampling” does not eliminate Monte Carlo uncertainty. **First implementation:** two-node light-tailed renewal network; measure sample generation cost versus ordinary warm-up DES and verify marginal/reference distributions.

#### A31. Rare-event importance sampling and splitting

**Next; extension; effort H.** Extend beyond the narrow current importance-sampling example using state-dependent tilting or adaptive splitting. Dupuis-Sezer-Wang study dynamic importance sampling for queueing networks; Cerou-Guyader provide an adaptive splitting foundation. [P32](https://arxiv.org/abs/0710.4389), [P33](https://www.tandfonline.com/doi/abs/10.1080/07362990601139628)

**Advantages:** more efficient estimation of extreme congestion/overflow than naive DES. **Disadvantages:** incorrect likelihood ratios or poor levels can produce misleading results; event-hitting probability is not the same as stationary full-buffer probability. **First implementation:** a small tandem with independently checkable overflow probabilities. For stationary tails, use properly defined stationary or regenerative reward estimators and account for particle dependence. Keep rare-event estimates separate from whole-distribution solvers.

#### A32. Poisson-equation controls and learned test functions

**Near/Next; new hybrid layer; effort H.** Use an approximate Poisson solution to construct martingale controls for simulation. Henderson-Glynn provide a principled way to use analytic approximations without treating their stationary means as exact controls. Qu-Blanchet-Glynn's recent work explores neural Lyapunov functions, Poisson equations and stationary distributions. [P31](https://web.stanford.edu/~glynn/papers/2002/HendersonG02.pdf), [P44](https://arxiv.org/abs/2508.16737)

**Advantages:** lets Qnet's existing analytical solvers help its discrete simulation; targets metrics rather than full state densities. **Disadvantages:** overhead can outweigh variance reduction; approximation quality is metric-dependent; learned Lyapunov candidates are not automatically globally valid proofs. **First implementation:** an exact-generator CTMC with an independently fitted control; then extend to Markovized general queues. Using a diffusion generator in place of the actual queue generator can introduce bias.

## 6. My proposed combinations and research approaches

The following are proposed designs, not claims of new proved theorems or priority over existing research. Their components have literature precedents; their value here is how they could fit together inside Qnet.

### H1. BAR point estimate plus independently verified metric interval

Use spectral, LP or neural output to identify likely density/tail shape. Fit a dual test function for the user's metric, then validate its drift and face inequalities independently. Stop when a verified interval is sufficiently narrow, rather than when a residual is merely small.

**Advantage:** practical estimates plus meaningful error evidence. **Risk:** a tight certificate may be much harder than a good estimate. Failure to certify must return “uncertified,” not invalidate a separately sound simulation estimate. **Prototype:** 2D box mean inventory, then orthant mean workload. Inspired by P24/P39 and moment-bounding work.

### H2. Exact boundary-region CTMC with an RBM tail

Treat small queue counts, priority switching and finite blocking states discretely. Couple that region to a diffusion approximation for large workloads through matched probability flux and selected moments.

**Advantage:** retains discrete behavior where diffusion is least reliable while reducing large-state cost. **Risk:** interface matching can violate conservation, double-count mass or introduce negative densities; rigorous error bounds are not supplied by this proposal. **Prototype:** one PH queue, then a two-node network. Compare to exact truncation and test sensitivity to moving the interface. This is a research project, not a quick interpolation between two answers.

### H3. Low-dimensional exact-transform blocks inside a network approximation

Identify a tightly coupled pair of bottlenecks; solve its 2D RBM transform using A26. Connect other stations through an explicitly approximate decomposition, propagating more than just mean/SCV where feasible.

**Advantage:** could preserve important pairwise dependence without a full high-dimensional solve. **Risk:** exact local blocks do not make the assembled network exact; feedback correlations and consistency between overlapping blocks are difficult. **Prototype:** three stations with two adjacent bottlenecks, compared against both whole-network SRBM and queue DES. Distinguish this from the existing SBD rather than simply rename SBD.

### H4. Nonnegative transform approximation beyond independent exponential products

Fit a positive mixture of tractable multivariate or PH-based component distributions and corresponding face measures to BAR information. On the nonnegative real axis, use normalization and complete-monotonicity constraints/checks; complex inversion additionally needs analytic consistency. Allow dependence within components and use exact 2D transforms as candidate building blocks.

**Advantage:** valid distribution representations can prevent impossible recovered moments and give cheap samples/marginals. **Risk:** representation bias; too many components; fitting a valid distribution does not prove it is the stationary one. This must be a substantive extension of Qnet's existing exponential-mixture BAR prototype, not another independent-product ansatz. **Prototype:** deliberately correlated 2D/3D RBM, not only product-form examples.

### H5. Distributional robustness and solver-disagreement dashboard

For a model specified by mean/SCV only, compare several compatible service shapes and selected dependence scenarios. Run structurally different solvers: exact/fitted CTMC, diffusion and DES. Allocate more computation where estimates disagree relative to their numerical/statistical uncertainty.

**Advantage:** exposes missing-input sensitivity and systematic approximation weaknesses. **Risk:** a finite scenario envelope is not a rigorous worst-case bound, and agreement is not proof of correctness. **Prototype:** fixed mean/SCV with Erlang/hyperexponential/other admissible fits and bottleneck-load sweeps. Motivated by P52; report the envelope as sensitivity, not a confidence interval.

### H6. Reliability-state switching diffusion for manufacturing lines

Keep a finite Markov chain for machine failure/repair states while using workload diffusion within each environment state, rather than averaging reliability into one effective service variance. Solve coupled stationary weak equations, with regime-specific boundary rules.

**Advantage:** could retain long failure episodes and their correlation with inventory while being cheaper than a fully discrete PH network. **Risk:** singular/regime-dependent covariance, boundary compatibility and state-space growth; a stable averaged model may conceal problematic regimes. **Prototype:** one finite buffer with two machines and one failure mode each, checked against the exact fluid/discrete models. This is an exploratory bridge between A08 and A09, not a direct consequence of either paper.

## 7. Proposed implementation order and release gates

This sequence is an assessment, not authorization to make changes.

| Stage | Deliverables | What must be true before promotion |
|---|---|---|
| 1. Model contracts and reference cases | Explicit priority/preemption, populations, reliability and blocking semantics; exact small CTMC examples; closed/priority DES cases | No silent coercion to FCFS, loss, open or single-class models |
| 2. Mature coverage gains | A10 exact MVA; A01 first PH/MAP adapters; A06 exact transfer blocks; A15 supported priority RBM | Exact/simulation comparisons for every admitted subclass |
| 3. Distributional Brownian analysis | A21 exact RBM cases; A26 2D transform solver; A27 inversion; A09 bounded-domain consistency | Probability/moment/flux tests, difficult parameter cases, independent numerical checks |
| 4. New special networks | A07 transfer decomposition; A14 closed loops; A17 priority OU; A13 closed Brownian simplex | Correct geometry and observable mapping; validated model-error behavior |
| 5. Confidence and scale | A02 certified truncation; A24/A25 BAR bounds; A32 controls; A11 larger closed systems; A31 rare events | Certificates explicitly separated from heuristics and asymptotic intervals |
| 6. Experimental frontier | A29 neural BAR; A04 high-order diffusion; H1-H6 hybrids; A05 tensor scaling | Replicated non-product-form tests, out-of-training examples, no unsupported accuracy claims |

If only **three algorithmic projects** can be funded next, I would choose **A15 priority re-entrant RBM, A26/A27 the 2D transform route, and A10 exact closed-network MVA**. They align closely with the requested research interests and offer different, independently valuable capabilities. For immediate industrial transfer-line use, move **A06/A07** ahead of the transform project. The small OU model A17 is an attractive focused demonstration, but it should not displace the core open-network work.

### Benchmark suite to require

1. **Exact queues:** M/M/1, M/M/c, M/M/1/K, Jackson networks and supported BCMP models. Check not only means but distributions and tails where available.
2. **Non-product-form queues:** PH two-node examples; priority examples with distinct service rates; re-entrant feedback; exact finite blocking states. Match assumptions across solvers.
3. **Exact diffusions:** 1D reflected Brownian exponential law; bounded 1D truncated-exponential law; product-form orthant examples; non-product-form 2D exponential-sum cases; ordinary OU Gaussian examples.
4. **Priority limits:** FBFS/LBFS examples; the Dai-Huo two-station five-class policy; the two-class OU high-priority Gaussian marginal. Sweep proximity to instability and load separation.
5. **Closed systems:** fixed total population, delay centers, class-population conservation, simplex Brownian examples, CONWIP loops and potentially deadlocked finite loops.
6. **Manufacturing:** failure-free and zero-buffer limits; unequal speeds; rare long repairs; several small finite exact cases and longer DES cases.
7. **Adversarial numerical cases:** nearly singular covariance, strong oblique reflection, small drift margin, tiny/large buffers, strongly correlated arrivals, heavy tails and nonexisting moments.

Use, for example, loads around 0.3, 0.7, 0.9 and 0.98 as a proposed experimental grid, not as universal accuracy thresholds. Test multiple distribution shapes at the same moments. Record wall-clock/memory and failure behavior on the user's hardware before assigning practical dimension limits.

### Result contract and GUI implications

Every method should declare the original model admitted, the actual process solved, supported outputs, and the assumptions it checked. Recommended result labels are:

- Exact queue model, up to numerical tolerance.
- Exact/fitted Markov model with a separate fitting error caveat.
- Queue approximation, with numerical diagnostics but no model-error certificate.
- Diffusion result, with a separate queue-to-diffusion caveat.
- Simulation estimate, with interval type, effective information and initialization treatment.
- Verified bound, naming the theorem/inequality and the assumptions actually verified.

The comparison screen should show separate measures for numerical convergence, approximation evidence and sampling uncertainty. Class delays, waiting probabilities, boundary rates, loss rates and throughput should not share a generic “queue length” result field. A method that only computes means should not expose a “joint distribution” action. Unsupported model features should explain why the method is unavailable.

These are suggested GUI consequences of the mathematical survey, not GUI changes made in this task.

## 8. Lower-priority directions and limits of this survey

Other useful areas include non-product-form mean-value approximations for general closed networks; power-series/light-traffic expansions with heavy-traffic interpolation; retrial queues; batch arrivals/service; multi-resource loss networks; fork-join/synchronization; and stochastic Petri-net models. They are not all interchangeable with open GJNs. Fork-join needs synchronization state, and a closed token loop with blocking may need reachability/deadlock analysis before a stationary solver.

I would not initially prioritize generic high-dimensional full-density neural PDE solvers, unconstrained maximum-entropy reconstruction from a few moments, or a universal OU closure. They can return plausible-looking densities without establishing accuracy for the intended network. Nor would I prioritize optimized control policies until fixed-policy performance and model semantics are dependable.

Some older articles and repository copies were unavailable for download. The index preserves the citations and download outcomes; no access controls were bypassed and no unavailable article is represented by an HTML page renamed as a PDF. Scope claims for unavailable papers are limited to accessible primary abstracts/records or clearly identified supporting papers. Book-length treatments by Neuts, Latouche-Ramaswami, Buzacott-Shanthikumar, Gershwin, and Harrison/Dai are useful background, but no unauthorized book copies were sought.

## 9. Paper library and recommended reading order

The requested library is in:

`/Users/nemecj/Library/CloudStorage/Dropbox/0_CODE/0_CLAUDE/2_QNET/Papers`

Read these first:

| Interest | Reading path |
|---|---|
| Priority re-entrant networks | P04 → P11 → P13 → P12/P15 |
| Priority OU | P38 → P24 Section 6 → P07 → P09 |
| Numerical BAR | P01/P02 → P05 → P24 → P39; consult P10/P40 for characterization caveats |
| RBM transforms | P19 → P21 → P23/P22 → P18 → P25/P46 |
| Neural BAR frontier | P16, especially experiments and Appendix B; then P44 |
| Closed networks | P51 record → P29 → P03 → P42 |
| Transfer lines | P48 record → P34/P35 → P43 → P06/P05 |
| Reliable reference computation | P26/P28 → P27 → P41 → P31/P32 |

The library includes unchanged public author/repository copies, not necessarily final journal versions. Original notices remain intact. Do not automatically include these research PDFs in the distributable Qnet `.app` or source release: availability for personal research is not a blanket redistribution license. P24 has an especially explicit preliminary-draft restriction.

The accompanying index records titles, authors, dates/version distinctions, stable source links, local filenames, page counts, and availability. The machine-readable manifest adds SHA-256 checksums and verification metadata. No Qnet algorithm or GUI code was modified.
