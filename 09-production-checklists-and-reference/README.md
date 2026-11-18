# Module 09: Production Readiness Checklists & Master Quick Reference

> **Navigation**: [Fellowship Portal](../README.md) > [Week 09: Incident Response & Control Plane Ops](../fellowship/week-09-incident-response-and-control-plane-ops/WEEK.md) > **Module 09: Production Readiness Checklists & Master Reference**
> - **Version Baseline (November 2026)**: Istio `1.32.0` | Envoy `v1.40` | Kubernetes `v1.36+` | Gateway API `v1.6.1` — see [`../VERSIONS.md`](../VERSIONS.md) and [`../COMPATIBILITY.md`](../COMPATIBILITY.md).
> - **Fellowship Cohort 01 Mapping**: Complete this module alongside **[Week 09: Incident Response & Control Plane Ops](../fellowship/week-09-incident-response-and-control-plane-ops/WEEK.md)**.
> - **Next Milestone**: **[Module 10: NovaPay Capstone Project](../10-capstone-project/README.md)**

---

## NovaPay Engineering Briefing: The Pre-Production Architecture Sign-Off

> **Alex Morgan (Senior Platform Engineer)**, **Sarah Chen (SRE Lead)** & **Maya Patel (Principal Security Engineer)**:
> "At **NovaPay**, no microservice or namespace is allowed to receive live PCI-DSS customer payment traffic until it passes our **7-Pillar Production Readiness Sign-Off**. Every single item in the checklists below was born from a real production outage or security audit finding across the FinTech industry—from forgotten unnamed MySQL ports (`5s` sniffing hangs) and un-scoped `Sidecar` CRDs ($O(N^2)$ Envoy OOMKills) to `PERMISSIVE` mTLS gaps and Prometheus cardinality explosions.
>
> Use **Part 1** as your mandatory pre-flight gate before launching the **Module 10 NovaPay Capstone Mesh** (and in your own enterprise architecture reviews), and bookmark **Part 2 (Master `istioctl` & Envoy Reference Cheat Sheet)** for your daily on-call incident response."

---

## Part 1: Comprehensive Production Readiness Checklists

### 1. Control Plane (`istiod`) Architecture, HA, & Security Checklist

- [ ] **Multi-Replica High Availability**: `istiod` runs with at least `3` replicas (`replicaCount: 3`) and a `HorizontalPodAutoscaler` (`minReplicas: 3`, `maxReplicas: 10`, target CPU `70%`).
- [ ] **Zone Anti-Affinity & PDB**: `istiod` pods are spread across availability zones (`topologyKey: topology.kubernetes.io/zone`) and protected by a `PodDisruptionBudget` (`minAvailable: 2`).
- [ ] **Guaranteed Resource Requests**: `istiod` has production-sized CPU/memory requests (`>= 500m` CPU, `>= 2Gi` RAM) so the Kubernetes scheduler never places it on starved nodes or evicts it first under memory pressure.
- [ ] **External / Offline Root CA Integration**: The default self-signed `istio-ca-secret` is replaced with an enterprise PKI intermediate CA (`cacerts` secret in `istio-system`) or integrated with **cert-manager** (`istio-csr`) / **HashiCorp Vault** / **Cloud CAS** so the Root CA private key never resides on the cluster.
- [ ] **Revision-Based Installation**: `istiod` is installed via Helm (or `istioctl`) with an explicit `revision` (e.g., `1-32-0`) rather than an unversioned in-place deployment, enabling canary control plane upgrades from `1-31-0` to `1-32-0` and instant namespace-level rollbacks.
- [ ] **Validation Webhook Active**: The `ValidatingWebhookConfiguration` (`istio-validator-istio-system`) is active with `failurePolicy: Fail` in production so malformed Istio CRDs are rejected at `kubectl apply` time.
- [ ] **CI/CD Pre-Flight Validation**: All GitOps pipelines (ArgoCD / Flux / GitHub Actions) run `istioctl analyze` against candidate YAML manifests before merging to main.

---

### 2. Data Plane (`istio-proxy` / `ztunnel`) Resource, Lifecycle & CNI Checklist

- [ ] **Istio CNI Plugin Enabled**: `istio-cni` is deployed in production so application pods do **not** require a privileged `istio-init` container with `NET_ADMIN` / `NET_RAW` capabilities to program `iptables`.
- [ ] **Native Kubernetes Sidecar Containers Enabled**: On Kubernetes `1.29+` / `1.36+`, `ENABLE_NATIVE_SIDECARS=true` (`KEP-753`) is enabled so `istio-proxy` starts before main containers (eliminating startup connection race conditions) and terminates automatically when Kubernetes `Job` / `CronJob` containers finish.
- [ ] **Graceful Connection Draining**: `terminationDrainDuration` (`30s`+) and `EXIT_ON_ZERO_ACTIVE_CONNECTIONS: "true"` are configured in `meshConfig.defaultConfig`, paired with a `preStop: sleep 5` hook on application containers to eliminate `503 UC/UF` errors during rolling deployments.
- [ ] **Per-Workload Proxy Sizing**: High-throughput services override default proxy CPU/memory requests and concurrency via `sidecar.istio.io/proxyCPU`, `sidecar.istio.io/proxyMemory`, and `proxy.istio.io/config` (`concurrency: 2` or `4`).
- [ ] **Gateway Separation & Autoscaling**: `istio-ingressgateway` and `istio-egressgateway` run as standalone `Deployment` workloads (decoupled from the `istiod` lifecycle), scaled independently via HPA across availability zones with a `PodDisruptionBudget`.

---

### 3. Traffic Management & Service Discovery Checklist

- [ ] **100% Explicit Service Port Naming**: Every port in every Kubernetes `Service` specifies either an explicit Istio protocol prefix (`name: http-api`, `name: grpc-rpc`, `name: tcp-mysql`, `name: tls-external`) or the Kubernetes `appProtocol` field (`appProtocol: http`). Zero unnamed ports exist on server-first protocols (MySQL, Redis, MongoDB).
- [ ] **Namespace-Scoped `Sidecar` CRDs Deployed**: Every application namespace contains a default `Sidecar` CRD restricting `egress.hosts` to only `istio-system/*` and the specific upstream namespaces/services that workloads in that namespace actually call, preventing $O(N^2)$ Envoy memory bloat and xDS push delays.
- [ ] **`DestinationRule` Applied Before `VirtualService` Subsets**: Deployment pipelines apply `DestinationRule` subset definitions **before** (or atomically with) any `VirtualService` referencing those subsets, and wait a few seconds before routing traffic to prevent transient `503 NR` errors.
- [ ] **Explicit Host Scoping (`exportTo`)**: `VirtualService`, `DestinationRule`, and `ServiceEntry` objects specify `exportTo: ["."]` (or explicit consumer namespaces) rather than leaking globally across all namespaces by default.
- [ ] **Istio DNS Capture Enabled**: `ISTIO_META_DNS_CAPTURE: "true"` and `ISTIO_META_DNS_AUTO_ALLOCATE: "true"` are enabled in `meshConfig.defaultConfig.proxyMetadata` so external `ServiceEntry` hosts and multi-cluster services resolve deterministically inside pods.

---

### 4. Zero-Trust Security Checklist

- [ ] **Mesh-Wide `STRICT` mTLS**: A root `PeerAuthentication` policy in `istio-system` enforces `mtls.mode: STRICT` across the entire mesh (or per-namespace `STRICT` policies where legacy migration is complete).
- [ ] **Dedicated `ServiceAccount` per Microservice**: Every `Deployment` / `StatefulSet` uses its own dedicated Kubernetes `ServiceAccount` (`automountServiceAccountToken: false` if the app does not call the K8s API directly). No production workload runs under the `default` `ServiceAccount`.
- [ ] **Default-Deny (`allow-nothing`) Authorization Baseline**: Every application namespace starts with an empty-spec `AuthorizationPolicy` (`spec: {}`) that denies all traffic by default unless explicitly permitted by an `ALLOW` rule.
- [ ] **Explicit SPIFFE Principal & Method Allow-Listing**: `AuthorizationPolicy` rules combine **L4 cryptographic identity** (`from.source.principals: ["cluster.local/ns/<ns>/sa/<sa>"]`) with **L7 HTTP attributes** (`to.operation.methods` and `to.operation.paths`).
- [ ] **Safe `DENY` Policy Logic**: Any `DENY` `AuthorizationPolicy` using negative matching (`notPrincipals`, `notNamespaces`, `notPaths`) is carefully audited and tested so that multiple fields under a single `from`/`to` block do not create an unintended logical `AND` bypass.
- [ ] **Controlled Egress (`REGISTRY_ONLY`)**: `meshConfig.outboundTrafficPolicy.mode` is set to `REGISTRY_ONLY`, and external APIs are explicitly registered via `ServiceEntry` resources (and routed through `istio-egressgateway` with `AuthorizationPolicy` checks where compliance requires egress auditing).

---

### 5. Resilience & Progressive Delivery Checklist

- [ ] **Explicit HTTP Timeouts**: Every `VirtualService` defines an explicit `timeout` (override Istio's default disabled/infinite route timeout) tuned to the downstream caller's SLA budget.
- [ ] **Bounded Retries with `perTryTimeout`**: Retries are configured **only** on idempotent endpoints (or safe connection failures like `connect-failure,reset`), with low `attempts` (`2` or `3`) and a `perTryTimeout` strictly shorter than the overall route `timeout` to prevent retry storms.
- [ ] **Circuit Breaking (`connectionPool`)**: Critical upstream services define `DestinationRule` connection pool limits (`maxConnections`, `http1MaxPendingRequests`, `http2MaxRequests`) to fail fast (`503 UO`) rather than queueing unbounded requests until pods OOMKill.
- [ ] **Outlier Detection (Passive Health Checking)**: `outlierDetection` (`consecutive5xxErrors`, `interval`, `baseEjectionTime`, `maxEjectionPercent: 50`) is enabled on upstream `DestinationRule` resources so degraded pods are temporarily ejected from the load-balancing pool before Kubernetes `readinessProbe` catches up.
- [ ] **Upstream HTTP Keep-Alive Alignment**: Application server idle keep-alive timeouts (e.g., Node.js `keepAliveTimeout`, Go `IdleTimeout`) are set **higher** than Envoy's upstream idle timeout (`idleTimeout` in `DestinationRule`) to prevent `503 UC` keep-alive race conditions.

---

### 6. Observability & Telemetry Checklist

- [ ] **Structured JSON Access Logging**: Envoy access logs use `JSON` encoding (`accessLogEncoding: JSON`) with trace correlation fields (`x-b3-traceid` / `traceparent`), `%RESPONSE_FLAGS%`, `%RESPONSE_CODE_DETAILS%`, and `%UPSTREAM_CLUSTER%`.
- [ ] **High-Volume Access Log Filtering**: High-QPS services use the `Telemetry` API with CEL filter expressions (`response.code >= 400 || response.flags != '-' || response.duration > duration('500ms')`) to log errors and slow requests while saving disk/SIEM ingestion costs on healthy `200 OK` health checks.
- [ ] **Metric Cardinality Control**: Custom `Telemetry` metric tags never include unbounded high-cardinality values (such as user IDs, session IDs, UUIDs, or raw request URLs) that could crash Prometheus.
- [ ] **Distributed Tracing Header Propagation**: Every application service propagates W3C (`traceparent`, `tracestate`, `baggage`), Envoy (`x-request-id`), and B3 (`x-b3-traceid`, `x-b3-spanid`, `x-b3-sampled`) headers from inbound requests to outbound calls, and trace sampling in production is tuned (`0.1%` to `1.0%` head-based or OTel Collector tail-based).

---

### 7. Day-2 Upgrade & Maintenance Runbook Checklist

- [ ] **Pre-Upgrade Compatibility Check**: Run `istioctl x precheck` and `istioctl analyze --all-namespaces` before installing any new Istio control plane revision.
- [ ] **Side-by-Side Canary Control Plane Deployment**: Install the new `istiod` revision (`istioctl install --set revision=<new-rev>`) and verify `istiod-<new-rev>` pods are healthy and running before touching any application namespace.
- [ ] **Staged Namespace Migration**: Relabel non-critical namespaces first (`istio.io/rev=<new-rev>`), perform a rolling restart (`kubectl rollout restart`), verify `istioctl proxy-status` and golden signals (`istio_requests_total`), and bake for 24–48 hours before migrating tier-1 production namespaces.
- [ ] **Certificate Expiration Monitoring**: Prometheus alerts are configured for `citadel_server_root_cert_expiry_timestamp` and workload SDS certificate expiration so CA rotation happens well before expiry.

---

## Part 2: Master `istioctl` & Envoy Admin Quick Reference Cheat Sheet

### 1. Essential `istioctl` Diagnostic Commands

| Task | Command |
| :--- | :--- |
| **Validate live cluster CRDs** | `istioctl analyze -n <namespace>` (or `-A` for all namespaces) |
| **Validate local YAML before applying** | `istioctl analyze -n <namespace> ./manifests/*.yaml` |
| **Check xDS sync status of all proxies** | `istioctl proxy-status` (or `istioctl ps`) |
| **Diff a pod's Envoy config against `istiod`** | `istioctl proxy-status <pod-name>.<namespace>` |
| **Check pre-upgrade cluster readiness** | `istioctl x precheck` |
| **Inspect how a pod is exposed/secured** | `istioctl x describe pod <pod-name>.<namespace>` |
| **Check active control plane revisions** | `istioctl tag list` |
| **Inspect Ztunnel workloads & certs (Ambient)** | `istioctl ztunnel-config workloads` / `istioctl ztunnel-config certificates` |

---

### 2. Deep Envoy xDS Config Inspection (`istioctl proxy-config` / `pc`)

| xDS Layer | Command | Common Flags & Use Cases |
| :--- | :--- | :--- |
| **Listeners (LDS)** | `istioctl pc listener <pod>.<ns>` | `--port 8080 -o json` (Inspect filter chains, RBAC filters, and TLS inspector on a port) |
| **Routes (RDS)** | `istioctl pc route <pod>.<ns>` | `--name 8080 -o json` (Verify `VirtualService` match rules, subsets, timeouts, and retries) |
| **Clusters (CDS)** | `istioctl pc cluster <pod>.<ns>` | `--fqdn <svc.ns.svc.cluster.local> --subset v1 -o json` (Verify circuit breakers & mTLS mode) |
| **Endpoints (EDS)** | `istioctl pc endpoint <pod>.<ns>` | `--cluster "outbound\|8080\|\|<svc>"` (Verify endpoint Pod IPs and `HEALTHY`/`UNHEALTHY` status) |
| **Secrets (SDS)** | `istioctl pc secret <pod>.<ns>` | Verify SPIFFE X.509 workload cert (`default`), serial number, `VALID CERT`, and `ROOTCA` |
| **Bootstrap** | `istioctl pc bootstrap <pod>.<ns>` | Inspect initial Envoy bootstrap config, `istiod` address, and node metadata |
| **Loggers** | `istioctl pc log <pod>.<ns>` | `--level http:debug,router:debug,rbac:debug` (Dynamically change Envoy log verbosity) |

---

### 3. Essential Istio & Envoy Ports Reference

| Port | Component | Protocol | Purpose |
| :--- | :--- | :--- | :--- |
| **`15000`** | `istio-proxy` (Localhost only) | HTTP | Envoy Admin API (`/stats`, `/config_dump`, `/clusters`, `/logging`, `/ready`) |
| **`15001`** | `istio-proxy` | TCP | Envoy Outbound capture port (`iptables` redirects all outbound app traffic here) |
| **`15006`** | `istio-proxy` | TCP | Envoy Inbound capture port (`iptables` redirects all inbound pod traffic here) |
| **`15008`** | `istio-proxy` / `ztunnel` | HBONE (mTLS/HTTP2) | Ambient Mesh & Sidecar HBONE tunnel port |
| **`15010`** | `istiod` | gRPC (Plaintext) | Unencrypted xDS discovery port (disabled/internal debug only) |
| **`15012`** | `istiod` | gRPC (TLS) | Secure xDS & CA discovery port used by `pilot-agent` / `ztunnel` |
| **`15014`** | `istiod` | HTTP | Control plane Prometheus metrics (`/metrics`) and debug endpoints |
| **`15017`** | `istiod` | HTTPS | Kubernetes Mutating & Validating Admission Webhook server |
| **`15020`** | `pilot-agent` | HTTP | Merged Prometheus telemetry (`/stats/prometheus`), health check, and `/quitquitquit` |
| **`15021`** | `istio-proxy` | HTTP | Envoy health check port (`/healthz/ready`) probed by Kubelet and LoadBalancers |
| **`15053`** | `pilot-agent` (Localhost) | DNS (UDP/TCP) | Local Istio DNS proxy when `ISTIO_META_DNS_CAPTURE=true` |
| **`15090`** | `istio-proxy` | HTTP | Raw Envoy Prometheus stats (`/stats/prometheus`) |

---

### 4. Rapid Envoy Response Flags Decoder Card

| Flag | Meaning | First Command to Run |
| :--- | :--- | :--- |
| **`NR`** | **No Route Configured** | `istioctl analyze -n <ns>` and `istioctl pc route <client-pod>.<ns> --name <port> -o json` |
| **`UH`** | **No Healthy Upstream** | `istioctl pc endpoint <client-pod>.<ns> --cluster "outbound\|<port>\|<subset>\|<fqdn>"` |
| **`UF`** | **Upstream Connection Failure** | `istioctl pc cluster <client-pod>.<ns> --fqdn <fqdn> -o json` (check mTLS vs `PeerAuthentication`) |
| **`UO`** | **Upstream Overflow** | `kubectl exec <client-pod> -c istio-proxy -- pilot-agent request GET stats \| grep overflow` |
| **`UT`** | **Upstream Request Timeout** | `istioctl pc route <client-pod>.<ns> --name <port> -o json` (check `timeout` / `perTryTimeout`) |
| **`UC`** | **Upstream Connection Termination** | Check upstream app container logs for crash/keep-alive timeout or Service port protocol mismatch |
| **`DC`** | **Downstream Connection Termination** | Inspect caller/client timeout; client closed TCP socket before response finished |
| **`URX`** | **Upstream Retry Limit Exceeded** | Look at the companion flag (`UF,URX` or `UT,URX`) to find why every retry attempt failed |
| **`RL`** | **Rate Limited (`429`)** | Inspect `EnvoyFilter` local/external rate limit descriptors |
| **`UAEX`** | **Unauthorized External (`401`/`403`)** | Inspect `CUSTOM` `AuthorizationPolicy` and external authz service logs |

---

## Next Step: Build & Defend the NovaPay Production Mesh
Proceed to **[Module 10: Capstone Project — Architecting & Operating the "NovaPay" Multi-Namespace FinTech Production Mesh (`../10-capstone-project/README.md`)](../10-capstone-project/README.md)**.
