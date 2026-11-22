# Course Changelog & Modernization Log (`CHANGELOG.md`)

All significant curriculum updates, Istio/Kubernetes version migrations, and API modernizations are recorded in this file.

---

## [2.1.0] — 2026-11-18: Learning Experience Refinement & Modular Lesson Refactoring

### 1. Decomposition of Oversized Modules into 23 Focused, Progressive Lessons
To eliminate cognitive overload while preserving full engineering depth, Modules `01` through `08` were decomposed into 23 focused, 20–30 minute modular lessons (`0X-.../lessons/01-*.md`, etc.), with each module's `README.md` serving as the Module Synthesis & Milestone Hub:
- **Module 01 (`01-architecture-and-internals/lessons/`)**: Split into 4 lessons (*Control Plane & Sidecar Injection*, *Linux Netns & `iptables` Interception*, *Envoy xDS Pipeline & ADS*, and *Ambient Mode: `ztunnel`, HBONE & Waypoints*).
- **Module 02 (`02-service-discovery-and-routing/lessons/`)**: Split into 3 lessons (*K8s L4 Discovery vs. Istio EDS*, *`VirtualService`, `DestinationRule` & the Evaluation Order Trap*, and *Load Balancing Algorithms & `Sidecar` Scoping*).
- **Module 03 (`03-gateways-ingress-and-egress/lessons/`)**: Split into 3 lessons (*North-South Gateways & Edge TLS Modes*, *Kubernetes Gateway API `v1.6.1`*, and *Zero-Trust Egress & TLS Origination*).
- **Module 04 (`04-security-mtls-and-authz/lessons/`)**: Split into 3 lessons (*SPIFFE Identity & SDS Certificate Lifecycle*, *`PeerAuthentication` & mTLS Migration*, and *JWT Authn & `AuthorizationPolicy`*).
- **Module 05 (`05-resilience-and-fault-injection/lessons/`)**: Split into 3 lessons (*Timeouts, Bounded Retries & Retry Storms*, *Circuit Breaking & Outlier Detection*, and *Chaos Fault Injection & Locality Failover*).
- **Module 06 (`06-progressive-delivery/lessons/`)**: Split into 2 lessons (*Traffic Mirroring & Dark Launches*, and *Weighted Canary, Blue-Green & Argo Rollouts*).
- **Module 07 (`07-observability-and-telemetry/lessons/`)**: Split into 3 lessons (*Envoy Telemetry & Dual-Reporter Metrics*, *`Telemetry` API & CEL Error-Only Logs*, and *Distributed Tracing & Context Propagation*).
- **Module 08 (`08-debugging-and-production-operations/lessons/`)**: Split into 2 lessons (*5-Step Debugging Methodology & Envoy Response Flags*, and *Production Operational Pitfalls & Canary Control Plane Upgrades*).

### 2. Mentor-Led Apprenticeship Flow & 6-Part Diagram Walkthroughs
- Integrated **Alex Morgan's** mentorship (briefings, intuition analogies, production war stories, and challenges) alongside **Sarah Chen**, **Daniel Brooks**, and **Maya Patel** directly into the core technical modules and lessons.
- Added structured **6-Part Mechanism Walkthroughs** (*What initiates it? Which component receives it? What information is exchanged? What changes in the system? How to observe it? What happens on failure?*) to architecture and sequence diagrams.
- Added **4-Tier Progressive Disclosure** (*Core Concept* $\rightarrow$ *Technical Deep Dive* $\rightarrow$ *Engineering Insight* $\rightarrow$ *Advanced Exploration*), **Knowledge Checks**, and **Definitions of Done** across every lesson.

### 3. Hands-On Lab Enhancements & Repository Quality Assurance
- Added **"Predict Before You Execute"** prompts, **Progressive Troubleshooting Hints** (`Hint 1` $\rightarrow$ `Hint 2` $\rightarrow$ `Full Explanation`), **Execution Verification Status** callouts, **Production Considerations**, and **Cleanup Procedures** to all `LAB.md` files and weekly incident drills.
- Resolved 15 relative link mismatches across `05`–`10` and `fellowship/week-10`, and unified `orderflow` workload/cluster naming in `fellowship/week-01` with `00-environment-setup/manifests/`.

---

## [2.0.0] — 2026-11-18: Transformation into "Istio Service Mesh Engineering Fellowship — Cohort 01" & Istio `1.32.0` Modernization

### 1. Authoritative Version Baseline Modernization
- **Istio Version**: Audited and upgraded the entire repository baseline from Istio `1.23`/`1.24` references to **Istio `1.32.0`** (Latest Stable Release, Nov 9, 2026), with **Istio `1.31.x`** used as the N-1 baseline for revision-based canary upgrade exercises.
- **Envoy Proxy Version**: Updated architecture and debugging documentation to reflect **Envoy `v1.40`** (`release/v1.40`).
- **Kubernetes Version**: Updated cluster baseline to **Kubernetes `v1.36` / `v1.37`** (within Istio `1.32`'s supported `1.33–1.37` window), reflecting GA `SidecarContainers` (`KEP-753`) enabled by default.
- **Kubernetes Gateway API**: Upgraded Gateway API installation manifests and labs from `v1.2.0` to **`v1.6.1`** (`standard-install.yaml`), incorporating the graduation of `TCPRoute` and `UDPRoute` to the `v1` Standard channel and Istio `1.32`'s support for `AuthorizationPolicy` `targetRefs` pointing to `HTTPRoute`.
- **CNI Compatibility Governance**: Added explicit **Cilium (`v1.18+`/`v1.19+`)** compatibility requirements (`cni.exclusive=false` and `socketLB.hostNamespaceOnly=true` when `kubeProxyReplacement=true`).

### 2. Installation & API Modernization (100% Official Helm Charts — Zero `IstioOperator` Manifests)
- **Eliminated Deprecated `IstioOperator` Manifests**: Removed all `kind: IstioOperator` (`install.istio.io/v1alpha1`) YAML manifests (`istio-operator-demo-vs-prod.yaml` and `production-istiod-ha-iop.yaml`) and replaced all installation and canary control-plane upgrade labs with the **official Istio Helm charts** (`istio/base`, `istio/istiod`, `istio/gateway`) and modular Helm `values.yaml` files (`helm-values-istiod.yaml`, `helm-values-ingressgateway.yaml`, `helm-values-egressgateway.yaml`, `helm-values-prod.yaml`, and `production-istiod-ha-helm-values.yaml`).
- **Standardized `v1` Istio CRDs**: Verified that all 49 YAML manifests use `networking.istio.io/v1`, `security.istio.io/v1`, `telemetry.istio.io/v1`, and `gateway.networking.k8s.io/v1`.
- **Addon & Sample URLs**: Updated observability addon references (`prometheus`, `jaeger`, `grafana`, `kiali`) and JWKS sample URLs from `release-1.24` to `release-1.32`.

### 3. Cohort-Based Engineering Fellowship Architecture
- Created **`FELLOWSHIP_HANDBOOK.md`**, **`PROGRESSION_DASHBOARD.md`**, reusable templates in **`fellowship/templates/`**, and the **10-Week Cohort Curriculum (`fellowship/week-01/` through `fellowship/week-10/`)**.

---

## [1.0.0] — 2026-11-17: Initial Hands-On Istio Course Release
- Created Modules `00` through `10` covering Istio architecture, Envoy internals, Ambient mode, traffic routing, Gateways, SPIFFE mTLS, `AuthorizationPolicy`, resilience, progressive delivery, `Telemetry` API, war-room debugging scenarios, production checklists, and the NovaPay capstone project.
