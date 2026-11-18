# Fellowship Progression & Competency Dashboard (`PROGRESSION_DASHBOARD.md`)

**Program:** Istio Service Mesh Engineering Fellowship — Cohort 01  
**Baseline:** Istio `1.32.0` | Envoy `v1.40` | Kubernetes `1.36/1.37` | Gateway API `v1.6.1`  
**Primary Mentor:** Alex Morgan (Senior Platform Engineer, NovaPay)

> **Graduation Policy:** Completion is **never** awarded merely for reading lecture notes. To advance from one phase to the next—and ultimately earn Fellowship Graduation—you must execute the guided labs, complete the independent Thursday engineering ticket, resolve and document the Friday incident drill, defend your architecture in Saturday's review, and pass Sunday's assessment.

---

## 1. Master 10-Week Progression Tracker

Check off (`[x]`) each deliverable only after verifying the acceptance criteria on your cluster:

| Week | Phase | Guided Lab (`LAB.md`) | Engineering Ticket (`Thursday`) | Incident Postmortem (`Friday`) | Architecture Review (`Saturday`) | Weekly Assessment (`Sunday`) | Status |
| :--- | :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| **[Week 01](./fellowship/week-01-platform-onboarding/WEEK.md)** | Phase 1 | `[ ]` [Lab 00](./00-environment-setup/LAB.md) | `[ ]` `NP-101` | `[ ]` `INC-01` | `[ ]` Defended | `[ ]` ___ / 5 | `PENDING` |
| **[Week 02](./fellowship/week-02-dataplane-internals-and-ambient/WEEK.md)** | Phase 1 | `[ ]` [Lab 01](./01-architecture-and-internals/LAB.md) | `[ ]` `NP-102` | `[ ]` `INC-02` | `[ ]` Defended | `[ ]` ___ / 5 | `PENDING` |
| **[Week 03](./fellowship/week-03-service-discovery-and-l7-routing/WEEK.md)** | Phase 2 | `[ ]` [Lab 02](./02-service-discovery-and-routing/LAB.md) | `[ ]` `NP-103` | `[ ]` `INC-03` | `[ ]` Defended | `[ ]` ___ / 5 | `PENDING` |
| **[Week 04](./fellowship/week-04-edge-gateways-and-controlled-egress/WEEK.md)** | Phase 2 | `[ ]` [Lab 03](./03-gateways-ingress-and-egress/LAB.md) | `[ ]` `NP-104` | `[ ]` `INC-04` | `[ ]` Defended | `[ ]` ___ / 5 | `PENDING` |
| **[Week 05](./fellowship/week-05-zero-trust-security-architecture/WEEK.md)** | Phase 2 | `[ ]` [Lab 04](./04-security-mtls-and-authz/LAB.md) | `[ ]` `NP-105` | `[ ]` `INC-05` | `[ ]` Defended | `[ ]` ___ / 5 | `PENDING` |
| **[Week 06](./fellowship/week-06-resilience-and-chaos-engineering/WEEK.md)** | Phase 3 | `[ ]` [Lab 05](./05-resilience-and-fault-injection/LAB.md) | `[ ]` `NP-106` | `[ ]` `INC-06` | `[ ]` Defended | `[ ]` ___ / 5 | `PENDING` |
| **[Week 07](./fellowship/week-07-progressive-delivery-and-safe-releases/WEEK.md)** | Phase 3 | `[ ]` [Lab 06](./06-progressive-delivery/LAB.md) | `[ ]` `NP-107` | `[ ]` `INC-07` | `[ ]` Defended | `[ ]` ___ / 5 | `PENDING` |
| **[Week 08](./fellowship/week-08-observability-and-golden-signals/WEEK.md)** | Phase 3 | `[ ]` [Lab 07](./07-observability-and-telemetry/LAB.md) | `[ ]` `NP-108` | `[ ]` `INC-08` | `[ ]` Defended | `[ ]` ___ / 5 | `PENDING` |
| **[Week 09](./fellowship/week-09-incident-response-and-control-plane-ops/WEEK.md)** | Phase 4 | `[ ]` [Lab 08](./08-debugging-and-production-operations/LAB.md) | `[ ]` `NP-109` | `[ ]` `INC-09` | `[ ]` Defended | `[ ]` ___ / 5 | `PENDING` |
| **[Week 10](./fellowship/week-10-capstone-and-graduation-defense/WEEK.md)** | Phase 4 | `[ ]` [Capstone](./10-capstone-project/README.md) | `[ ]` `NP-110` | `[ ]` `INC-10` | `[ ]` Board Passed | `[ ]` ___ / 10 | `PENDING` |

---

## 2. Phase Gate Competency Matrix

### Phase 1 Gate: Foundation & Data Plane Internals (Weeks 1–2)
- `[ ]` **C1.1 — Control Plane Installation & Profiles**: Can install Istio `1.32.0` via Helm and `istioctl`, explain why the in-cluster `IstioOperator` was removed in `1.24`, and configure Cilium compatibility (`cni.exclusive=false`, `socketLB.hostNamespaceOnly=true`).
- `[ ]` **C1.2 — Envoy xDS & Interception Mechanics**: Can trace an outbound (`:15001`) and inbound (`:15006`) packet through `iptables` NAT chains (`UID 1337` loop prevention) and correlate `VirtualService`/`DestinationRule` fields to Envoy `LDS`, `RDS`, `CDS`, and `EDS` dumps.
- `[ ]` **C1.3 — Sidecar vs. Ambient Evaluation**: Can deploy workloads in Ambient Mode (`ztunnel` L4 DaemonSet over HBONE `:15008` + Gateway API `istio-waypoint` L7 proxy) and articulate the memory, latency, and blast-radius trade-offs vs. Sidecar Mode.

### Phase 2 Gate: Core Service Mesh Engineering (Weeks 3–5)
- `[ ]` **C2.1 — L7 Traffic Routing & Mesh Scaling**: Can eliminate L4/gRPC connection skew via Envoy `EDS`, prevent `503 NR` subset ordering outages, configure Ring-Hash session affinity, and reduce Envoy memory footprint by $>60\%$ using `Sidecar` CRDs.
- `[ ]` **C2.2 — Edge Gateways & Controlled Egress**: Can expose TLS-terminated services via **Kubernetes Gateway API `v1.6.1`** (`Gateway` + `HTTPRoute`), enforce `outboundTrafficPolicy.mode: REGISTRY_ONLY`, and route external API traffic through `istio-egressgateway` with TLS origination.
- `[ ]` **C2.3 — Zero-Trust Security Architecture**: Can inspect SPIFFE X.509 SANs via SDS, migrate a live namespace from `PERMISSIVE` to `STRICT` mTLS without downtime, enforce JWT `RequestAuthentication`, and author default-deny (`allow-nothing`) `AuthorizationPolicy` rules without falling into the YAML `AND`/`OR` list trap.

### Phase 3 Gate: Production Reliability & Operations (Weeks 6–8)
- `[ ]` **C3.1 — Resilience & Chaos Engineering**: Can design multi-tier timeout budgets satisfying the Timeout Math Rule, prevent cascading retry storms, trip and measure `connectionPool` circuit breakers (`503 UO`), and verify `outlierDetection` pod ejection (`failed_outlier_check`).
- `[ ]` **C3.2 — Progressive Delivery**: Can shadow live production traffic (`-shadow` authority header) while accounting for stateful side effects, execute header-based dark launches, and run staged weighted canary rollouts (`90/10` $\rightarrow$ `50/50` $\rightarrow$ `100%`).
- `[ ]` **C3.3 — Observability & Golden Signals**: Can distinguish `reporter="source"` vs. `reporter="destination"` metrics in PromQL, author `telemetry.istio.io/v1` resources with CEL error-only JSON access logs and bounded custom metric tags, and diagnose broken W3C `traceparent` / B3 header propagation.

### Phase 4 Gate: Advanced Architecture & Fellowship Graduation (Weeks 9–10)
- `[ ]` **C4.1 — Systematic War-Room Troubleshooting**: Can diagnose any Envoy response flag (`NR`, `UH`, `UF`, `UO`, `UT`, `UC`, `DC`, `UAEX`) in under 5 minutes using the 5-Step Troubleshooting Decision Tree and perform a zero-downtime revision-based canary upgrade of `istiod` (`1-31-0` $\rightarrow$ `1-32-0`).
- `[ ]` **C4.2 — NovaPay PCI Production Capstone & Defense**: Has deployed the multi-namespace `novapay` + `novapay-pci` production architecture, passed `./10-capstone-project/verify-capstone.sh` with 0 failures, resolved `INC-10`, and defended all 8 architectural decisions before the Graduation Board.

---

## 3. Incident Postmortem Log (`INC-01` – `INC-10`)

| Incident ID | Week | Outage Symptom / Envoy Response Flag | Root Cause Identified | Postmortem Completed |
| :--- | :--- | :--- | :--- | :---: |
| **`INC-01`** | Week 01 | Missing sidecar (`1/1 Ready`) & 5s protocol sniffing latency | Namespace label typo (`istio-injection: true` vs `enabled`) + unnamed Service port | `[ ]` |
| **`INC-02`** | Week 02 | `503 UF` on inbound `:15006` after sidecar injection | App bound to `127.0.0.1` instead of `0.0.0.0` (breaking inbound passthrough) | `[ ]` |
| **`INC-03`** | Week 03 | `503 NR` (`No Route`) during canary deployment | `VirtualService` applied before `DestinationRule` subset existed (Evaluation Order Trap) | `[ ]` |
| **`INC-04`** | Week 04 | TLS handshake timeout / SDS secret missing at Ingress | TLS Secret created in workload namespace instead of gateway namespace (`istio-system`) | `[ ]` |
| **`INC-05`** | Week 05 | Unauthorized workload bypassed `AuthorizationPolicy` | YAML list item split created logical `OR` instead of logical `AND` in policy rule | `[ ]` |
| **`INC-06`** | Week 06 | Premature `504 UT` while upstream still charged card | Overall `VirtualService.timeout` set smaller than `attempts * perTryTimeout` | `[ ]` |
| **`INC-07`** | Week 07 | Dark-launch header ignored; all traffic hit catch-all route | Catch-all route rule placed *above* header-match rule in `VirtualService.spec.http[]` | `[ ]` |
| **`INC-08`** | Week 08 | Fragmented 1-span traces in Jaeger & Prometheus OOM | Missing `traceparent` propagation in app + high-cardinality `user_id` metric tag | `[ ]` |
| **`INC-09`** | Week 09 | Orphaned `STALE` proxies during `istiod` canary upgrade | Conflicting `istio-injection` + `istio.io/rev` labels & premature removal of N-1 `istiod` | `[ ]` |
| **`INC-10`** | Week 10 | Multi-fault outage across `novapay` and `novapay-pci` | Cross-namespace SPIFFE authz mismatch + external `ServiceEntry` port/TLS conflict | `[ ]` |

---

## 4. Final Fellowship Graduation Sign-Off

To graduate from **Cohort 01 of the Istio Service Mesh Engineering Fellowship**:
1. All 10 Guided Labs, 10 Thursday Engineering Tickets (`NP-101`–`NP-110`), and 10 Friday Incident Simulations (`INC-01`–`INC-10`) above are checked `[x]`.
2. Cumulative Sunday Assessment score is at least **45 / 55 (82%+)**.
3. The automated Capstone Verification Script passes all 6 production pillars:
   ```bash
   ./10-capstone-project/verify-capstone.sh
   ```
4. You have completed the **Saturday Graduation Defense Board** in [Week 10](./fellowship/week-10-capstone-and-graduation-defense/WEEK.md).

