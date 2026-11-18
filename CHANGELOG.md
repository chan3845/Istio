# Course Changelog & Modernization Log (`CHANGELOG.md`)

All significant curriculum updates, Istio/Kubernetes version migrations, and API modernizations are recorded in this file.

---

## [2.0.0] — 2026-11-18: Transformation into "Istio Service Mesh Engineering Fellowship — Cohort 01" & Istio `1.32.0` Modernization

### 1. Authoritative Version Baseline Modernization
- **Istio Version**: Audited and upgraded the entire repository baseline from Istio `1.23`/`1.24` references to **Istio `1.32.0`** (Latest Stable Release, Nov 9, 2026), with **Istio `1.31.x`** used as the N-1 baseline for revision-based canary upgrade exercises.
- **Envoy Proxy Version**: Updated architecture and debugging documentation to reflect **Envoy `v1.40`** (`release/v1.40`).
- **Kubernetes Version**: Updated cluster baseline to **Kubernetes `v1.36` / `v1.37`** (within Istio `1.32`'s supported `1.33–1.37` window), reflecting GA `SidecarContainers` (`KEP-753`) enabled by default.
- **Kubernetes Gateway API**: Upgraded Gateway API installation manifests and labs from `v1.2.0` to **`v1.6.1`** (`standard-install.yaml`), incorporating the graduation of `TCPRoute` and `UDPRoute` to the `v1` Standard channel and Istio `1.32`'s support for `AuthorizationPolicy` `targetRefs` pointing to `HTTPRoute`.
- **CNI Compatibility Governance**: Added explicit **Cilium (`v1.18+`/`v1.19+`)** compatibility requirements (`cni.exclusive=false` and `socketLB.hostNamespaceOnly=true` when `kubeProxyReplacement=true`).

### 2. Installation & API Modernization
- **Removed In-Cluster `IstioOperator` References**: Clarified across Module 00 and Module 08 that the *in-cluster* Istio Operator controller was deprecated in `1.23` and removed in `1.24`. Added modern **Helm values (`helm-values-prod.yaml`)** alongside local CLI `istioctl install` configurations.
- **Standardized `v1` Istio CRDs**: Verified that all 48+ YAML manifests use `networking.istio.io/v1`, `security.istio.io/v1`, `telemetry.istio.io/v1`, and `gateway.networking.k8s.io/v1`.
- **Addon & Sample URLs**: Updated observability addon references (`prometheus`, `jaeger`, `grafana`, `kiali`) and JWKS sample URLs from `release-1.24` to `release-1.32`.

### 3. Cohort-Based Engineering Fellowship Architecture
- Created **`FELLOWSHIP_HANDBOOK.md`** defining the **Istio Service Mesh Engineering Fellowship — Cohort 01**, the continuous **NovaPay** FinTech storyline, and the recurring engineering team (**Alex Morgan**, **Sarah Chen**, **Daniel Brooks**, **Maya Patel**).
- Created **`PROGRESSION_DASHBOARD.md`** providing a competency-based progression tracker, assignment checklist, incident postmortem log, and graduation defense rubric.
- Created reusable engineering templates in **`fellowship/templates/`** (`ENGINEERING_TICKET_TEMPLATE.md`, `INCIDENT_POSTMORTEM_TEMPLATE.md`, `ARCHITECTURE_REVIEW_RFC_TEMPLATE.md`, `WEEKLY_ASSESSMENT_TEMPLATE.md`).
- Created the **10-Week Cohort Curriculum (`fellowship/week-01/` through `fellowship/week-10/`)**, structuring every week into a 7-day engineering cadence (Monday Mentor Briefing $\rightarrow$ Tuesday Technical Lectures $\rightarrow$ Wednesday Guided Labs $\rightarrow$ Thursday Independent Engineering Assignment $\rightarrow$ Friday Incident Simulation $\rightarrow$ Saturday Architecture Review & Office Hours $\rightarrow$ Sunday Weekly Assessment & Reflection) seamlessly integrated with Modules `00`–`10`.

---

## [1.0.0] — 2026-11-17: Initial Hands-On Istio Course Release
- Created Modules `00` through `10` covering Istio architecture, Envoy internals, Ambient mode, traffic routing, Gateways, SPIFFE mTLS, `AuthorizationPolicy`, resilience, progressive delivery, `Telemetry` API, war-room debugging scenarios, production checklists, and the NovaPay capstone project.

