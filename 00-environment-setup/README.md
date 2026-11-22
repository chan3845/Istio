[Fellowship Portal](../README.md) | [Week 01 Guide](../fellowship/week-01-platform-onboarding/WEEK.md) | [Guided Lab (LAB.md)](./LAB.md) | [Next: Module 01 ->](../01-architecture-and-internals/README.md)

# Module 00: Environment Setup & The OrderFlow Reference Architecture

> **Version & Fellowship Context**
> - **Authoritative Baseline**: Istio `1.32.0` | Envoy `v1.40` | Kubernetes `v1.36+` (Supported: `1.33`–`1.37`) | Gateway API `v1.6.1` — see [`../VERSIONS.md`](../VERSIONS.md) and [`../COMPATIBILITY.md`](../COMPATIBILITY.md).
> - **Fellowship Cohort 01 Mapping**: Complete this module alongside **[Week 01: Platform Onboarding (`NP-101`)](../fellowship/week-01-platform-onboarding/WEEK.md)**.
> - **Estimated Completion Time**: `45 mins` (Reading + Cluster & Platform Provisioning Lab)
> - **Prerequisites**: Docker (`27.x+`), `kind` (`v0.27+`), `kubectl` (`v1.36+`), `istioctl` (`v1.32.0`), `helm` (`v3.16+` or `v4.x`), `jq`, and `openssl`.

### Module Learning Objectives
By the end of this module, you will be able to:
1. Explain how multi-node Kubernetes topology labels (`region`, `zone`), CNI plugins (including **Cilium CNI** socket-LB compatibility), and NodePort/LoadBalancer mappings interact with Istio `1.32.0`.
2. Evaluate Istio `1.32.0` installation methods (**Official Helm Charts** `istio/base`, `istio/istiod`, `istio/cni`, `istio/ztunnel`, `istio/gateway` vs. **`istioctl install --set`** CLI profiles) and configuration profiles (`default`, `demo`, `minimal`, `ambient`), explaining why `IstioOperator` and `profile=demo` are banned in production.
3. Deploy and verify the **OrderFlow E-Commerce & Payment Platform**—a multi-tier microservices call graph (`frontend` $\rightarrow$ `order-service` $\rightarrow$ `payment-service` & `inventory-service`) that propagates distributed trace headers and returns structured JSON call trees.

---

## 1. NovaPay Engineering Context & Alex Morgan's Briefing

### 1.1 What Is Happening at NovaPay?
At **NovaPay**, our core checkout and payment processing pipeline—**`orderflow`**—processes thousands of payment authorizations per second across multiple availability zones (`us-east-1a`, `us-east-1b`, `us-east-1c`). As we prepare for our upcoming **PCI-DSS Level 1 audit** and **Black Friday peak checkout volume**, Platform Engineering must establish a deterministic, auditable Istio `1.32.0` foundation before migrating production payment traffic.

Isolated `hello-world` containers (`httpbin` or single `nginx` pods) fail to expose the real failure modes that wake platform engineers up at 3:00 AM:
- Multi-hop latency amplification across cascading HTTP/gRPC calls (`frontend` $\rightarrow$ `order-service` $\rightarrow$ `payment-service`).
- Replica skew where `v1` has 2 pods and `v2` has 1 pod behind a single Kubernetes `Service`.
- Uninjected legacy callers (`legacy-uninjected`) communicating with mTLS-protected mesh workloads.
- Misnamed `Service` ports causing Envoy protocol-sniffing timeouts.

### 1.2 Alex Morgan's Briefing & Mental Model Analogy

> **Alex Morgan (Senior Platform Engineer — Mentor Briefing)**
> *"Welcome to the Platform Engineering team at NovaPay. Before we write a single `VirtualService` or mTLS policy, we need our proving ground stood up right—and we need to clear up two dangerous misconceptions I see in almost every service mesh migration.*
>
> *First: think of standard Kubernetes networking (`kube-proxy` + `Service` ClusterIPs) like **unmanaged city intersections with passive street signs**. Once a TCP connection leaves a pod, the kernel flips a coin at `SYN` time to pick a destination IP, and from that moment on, Kubernetes is blind. It doesn't know if the packet carries an HTTP `503`, a forged identity, or 10,000 multiplexed gRPC requests pinned to a dying pod. An Istio service mesh replaces those passive street signs with **an intelligent, programmable air-traffic control tower (`istiod`) in constant radio contact with an onboard co-pilot (`envoy` or `ztunnel`) inside every aircraft**.*
>
> *Second: we have two non-negotiable rules in Ticket `NP-101`:*
> 1. ***Never run `profile=demo` in staging or production.*** *Last year, a team copied `istioctl install --set profile=demo` from a quickstart guide into a staging load-test cluster. Because `demo` sets `100%` trace sampling, unthrottled `/dev/stdout` access logging, and `10m` CPU requests, Envoy saturated node disk I/O and throttled checkout latency from `18ms` to `1,400ms`.*
> 2. ***Never use `IstioOperator` manifests.*** *The old in-cluster `IstioOperator` controller required permanent cluster-admin privileges and was **deprecated in Istio 1.23 and permanently removed in Istio 1.24**. Even passing legacy `kind: IstioOperator` files to `istioctl install -f` is a deprecated anti-pattern. At NovaPay, we install and manage Istio `1.32.0` using the **official Istio Helm charts** (`istio/base`, `istio/istiod`, `istio/gateway`) in both our labs and production GitOps pipelines."*

---

## 2. Istio `1.32.0` Installation Methods & Configuration Profiles

### 2.1 Official Helm Charts (Primary Standard) vs. `istioctl install --set`

In Istio `1.32.0`, the authoritative installation and lifecycle mechanism is **Helm** (or `istioctl install --set profile=<name>` which renders the exact same underlying Helm charts in memory):

| Installation Method | How It Works | Target Environment |
| :--- | :--- | :--- |
| **1. Official Helm Charts (`istio/base`, `istio/istiod`, `istio/cni`, `istio/ztunnel`, `istio/gateway`)** | Standard Helm charts hosted at **`https://blob.istio.io/istio-release/charts`** (replacing the decommissioned GCP bucket `istio-release.storage.googleapis.com/charts`), rendered by `helm`, ArgoCD, or Flux using declarative `values.yaml` files (see [`manifests/helm-values-istiod.yaml`](./manifests/helm-values-istiod.yaml) for our lab and [`manifests/helm-values-prod.yaml`](./manifests/helm-values-prod.yaml) for production HA). | **Primary Standard Used in This Fellowship & Production GitOps.** Integrates natively with enterprise GitOps pipelines and revision-based canary upgrades (`istio.io/rev`). |
| **2. `istioctl install --set profile=<profile>`** | The `istioctl` CLI renders the compiled-in Helm charts using `--set` flags and applies them directly to the API server. | **Quick CLI Sandboxes & Diagnostics.** |

> [!WARNING]
> **Legacy / Historical Context — Why `IstioOperator` (`install.istio.io/v1alpha1`) Is Deprecated & Removed**
> Older Istio tutorials often use `kind: IstioOperator` YAML files. Historically, Istio included an *in-cluster* `IstioOperator` controller pod that watched `IstioOperator` custom resources inside the cluster. Because running a privileged operator with cluster-wide RBAC permissions inside the cluster created severe security and upgrade risks, the in-cluster `IstioOperator` controller was **deprecated in Istio 1.23 and permanently removed in Istio 1.24**.
>
> In **Istio `1.32.0`**, you should **never** author `kind: IstioOperator` manifests. Instead, use clean **Helm `values.yaml` files** with the official Istio Helm charts:
> - [`manifests/helm-values-istiod.yaml`](./manifests/helm-values-istiod.yaml) (Lab Control Plane values)
> - [`manifests/helm-values-ingressgateway.yaml`](./manifests/helm-values-ingressgateway.yaml) & [`manifests/helm-values-egressgateway.yaml`](./manifests/helm-values-egressgateway.yaml) (Gateway values)
> - [`manifests/helm-values-prod.yaml`](./manifests/helm-values-prod.yaml) (Production High-Availability Control Plane values)

### 2.2 Why Installation Profiles Matter & How `zzz_profile.yaml` Works in Helm vs. `istioctl`

In Istio `1.32.0`, configuration profiles work differently depending on whether you install via **Helm (`istio/istiod`)** or **`istioctl install`**:

> [!IMPORTANT]
> **Critical Istio `1.32.0` Helm Pitfall: Why `profile: default` Fails in `istio/istiod`**
> If you pass `--set profile=default` (or `profile: default` in `values.yaml`) to `helm install istiod istio/istiod`, Helm fails immediately with:
> ```text
> Error: execution error at (istiod/templates/zzz_profile.yaml:31:3):
> unknown profile default
> ```
> **Why does this happen under the hood?**
> 1. Inside the `istio/istiod` `1.32.0` chart, the built-in `values.yaml` (`_internal_defaults_do_not_set`) **is already the `default` profile**.
> 2. When `istiod/templates/zzz_profile.yaml` evaluates `.Values.profile`, if the value is non-empty, it calls `$.Files.Get (printf "files/profile-%s.yaml" .)`.
> 3. The chart's `files/` directory only packages **overlay profiles** (`profile-ambient.yaml`, `profile-demo.yaml`, `profile-preview.yaml`, `profile-remote.yaml`, `profile-stable.yaml`, plus platform overlays like `profile-platform-gke.yaml`). There is **no** `files/profile-default.yaml`!
> 4. Therefore, to use the standard production default profile in Helm, **omit `profile` (or set `profile: ""`)**. Also note: do **not** blindly substitute `profile: stable` for `default`—in Istio `1.32.0`, `profile-stable.yaml` enables `experimental.stableValidationPolicy: true` (an experimental admission policy that blocks non-GA fields).

| Profile (`istioctl`) | Helm Chart (`istio/istiod`) Equivalent | Key Defaults & Behavior | Target Environment |
| :--- | :--- | :--- | :--- |
| **`default`** | **Omit `profile` (or `profile: ""`)** *(Built into `values.yaml`)* | Production-safe defaults, `1%` trace sampling, standard resource requests (`100m` CPU / `128Mi` RAM per proxy). | **Production & Fellowship Baseline** (customized via Helm `values.yaml`). |
| **`demo`** | `profile: demo` (`files/profile-demo.yaml`) | `100%` trace sampling, verbose access logging, miniature CPU/memory requests (`10m` CPU / `40Mi` RAM). | **Never use in production.** High trace sampling and tiny resource requests cause severe CPU throttling under load. |
| **`ambient`** | `profile: ambient` (`files/profile-ambient.yaml`) + `istio/cni` & `istio/ztunnel` charts | Enables sidecarless Ambient Data Plane mode (`PILOT_ENABLE_AMBIENT: "true"`, `ISTIO_META_ENABLE_HBONE: "true"`). | **Ambient Mesh deployments** (covered in [Module 01 Lesson 04](../01-architecture-and-internals/lessons/04-ambient-mode-ztunnel-and-waypoints.md)). |
| **`stable`** | `profile: stable` (`files/profile-stable.yaml`) | Sets `experimental.stableValidationPolicy: true` to reject alpha/beta fields via admission control. | **Experimental strict-API validation clusters only** (not a drop-in replacement for `default`). |
| **`minimal`** | Install `istio/base` + `istio/istiod` without `istio/gateway` *(No `profile-minimal.yaml` in Helm)* | Control plane only; gateways are deployed separately as standalone Helm releases or via Gateway API. | **Enterprise GitOps** where gateways are managed separately or via Kubernetes Gateway API (`v1.6.1`). |

### 2.3 Cilium CNI Compatibility Requirements (Istio `1.32.0` Sidecar & Ambient Modes)

If your Kubernetes `v1.36+` cluster runs **Cilium CNI** (especially with eBPF `kubeProxyReplacement=true`), you **must** configure two critical Cilium settings so Cilium's eBPF programs do not bypass Istio's `istio-cni` netns redirection (`ztunnel`) or Envoy `iptables` socket interception:

1. **`cni.exclusive=false`**: Allows `istio-cni` to chain cleanly after Cilium in `/etc/cni/net.d/` so Istio can hook pod network namespaces at pod startup.
2. **`socketLB.hostNamespaceOnly=true`**: Restricts Cilium's eBPF socket-level load balancing (`bpf_sockaddr`) to the host network namespace only. Without this setting, Cilium rewrites Service ClusterIPs inside the pod's socket layer *before* packets ever reach Envoy (`:15001`) or `ztunnel` (`:15008`), breaking Istio mTLS, L7 routing, and Ambient HBONE tunnels!

### Our Engineering Approach
Instead of blindly installing `profile=demo` or using deprecated `IstioOperator` YAML files, we install Istio `1.32.0` using the **official Istio Helm charts** with explicit, modular Helm values files ([`manifests/helm-values-istiod.yaml`](./manifests/helm-values-istiod.yaml), [`manifests/helm-values-ingressgateway.yaml`](./manifests/helm-values-ingressgateway.yaml), [`manifests/helm-values-egressgateway.yaml`](./manifests/helm-values-egressgateway.yaml), and [`manifests/helm-values-prod.yaml`](./manifests/helm-values-prod.yaml)) so you see the exact Helm chart architecture used in modern production clusters.

---

## 3. The NovaPay `OrderFlow` Reference Microservices Architecture

Throughout Modules 00–09, we operate the **OrderFlow** checkout platform in the `orderflow` namespace. Every service runs `nicholasjackson/fake-service`, a purpose-built microservice simulator used in production service mesh benchmarks that:
- Makes **real upstream HTTP/gRPC calls** defined in `UPSTREAM_URIS`.
- Automatically propagates **W3C (`traceparent`) and B3 (`x-b3-*`) distributed tracing headers**.
- Returns a nested **JSON call graph** showing the exact pod IP, version, HTTP status code, and latency of every hop in the request chain.

```mermaid
flowchart LR
    subgraph LegacyNS["Namespace: legacy-uninjected (No Sidecars)"]
        LegacyClient["legacy-client (curl)<br/>SA: legacy-sa"]
    end

    subgraph OrderFlowNS["Namespace: orderflow (istio-injection: enabled)"]
        Toolbox["client-toolbox (curl)<br/>SA: toolbox-sa"]
        Frontend["frontend-v1<br/>SA: frontend-sa<br/>Port: 80 -> 8080"]
        
        OrderV1["order-service-v1 (2 replicas)<br/>SA: order-sa | Port: 8080"]
        OrderV2["order-service-v2 (1 replica)<br/>SA: order-sa | Port: 8080"]
        
        PayV1["payment-service-v1 (2 replicas)<br/>SA: payment-sa | Port: 8080"]
        PayV2["payment-service-v2 (1 replica)<br/>SA: payment-sa | Port: 8080"]
        
        InvV1["inventory-service-v1 (1 replica)<br/>SA: inventory-sa | Port: 8080"]
    end

    GW["istio-ingressgateway<br/>(Namespace: istio-system)"] --> Frontend
    Toolbox -.->|"In-Mesh Test Calls"| Frontend
    LegacyClient -.->|"Plaintext Calls"| OrderV1
    
    Frontend -->|"HTTP :8080"| OrderV1
    Frontend -->|"HTTP :8080"| OrderV2
    
    OrderV1 -->|"HTTP :8080"| PayV1
    OrderV1 -->|"HTTP :8080"| PayV2
    OrderV1 -->|"HTTP :8080"| InvV1
    
    OrderV2 -->|"HTTP :8080"| PayV1
    OrderV2 -->|"HTTP :8080"| PayV2
    OrderV2 -->|"HTTP :8080"| InvV1
```

### 3.1 6-Part Step-by-Step Architecture Walkthrough

1. **What initiates the operation?**
   An external customer call arriving via `istio-ingressgateway` (or an internal diagnostic probe from `client-toolbox` / `legacy-client`) sends an HTTP GET request to `http://frontend.orderflow.svc.cluster.local`.
2. **Which component receives it?**
   Inside the `orderflow` namespace (labeled `istio-injection=enabled`), every pod contains both the application container and an injected `istio-proxy` (`envoy` `v1.40`) sidecar container. The `frontend-v1` pod's Envoy proxy intercepts the inbound request on port `:15006`, forwards it to the local `frontend` container on `:8080`, and then intercepts `frontend`'s outbound call to `http://order-service.orderflow.svc.cluster.local:8080` on port `:15001`.
3. **What information is exchanged?**
   `frontend-v1` calls `order-service:8080`, propagating W3C (`traceparent`) and B3 (`x-b3-traceid`, `x-b3-spanid`) headers. `order-service` fans out concurrently to `inventory-service:8080` and `payment-service:8080`. Each Envoy proxy negotiates automatic SPIFFE mTLS (`spiffe://cluster.local/ns/orderflow/sa/<service-account>`) with its upstream peer and returns a nested JSON payload recording its pod IP, start/end timestamps, HTTP status code, and upstream call tree.
4. **What changes in the system?**
   Because both `order-service` and `payment-service` run **2 replicas of `v1`** and **1 replica of `v2`** behind a single Kubernetes `Service` selector (`app: order-service` and `app: payment-service`), Envoy's Endpoint Discovery Service (`EDS`) pool for each service contains 3 healthy Pod IPs—resulting in a baseline `66.7%` (`v1`) / `33.3%` (`v2`) traffic distribution until L7 routing policies are applied in Module 02.
5. **How can you observe/verify it on your cluster?**
   - Check injected container readiness (`2/2` in `orderflow` vs. `1/1` in `legacy-uninjected`):
     `kubectl get pods -n orderflow && kubectl get pods -n legacy-uninjected`
   - Trace the live multi-hop JSON call graph:
     `kubectl exec -n orderflow deploy/client-toolbox -c toolbox -- curl -s http://frontend.orderflow.svc.cluster.local | jq .`
   - Verify xDS synchronization across all proxies:
     `istioctl proxy-status`
6. **What happens if a component fails?**
   - If `payment-service-v2` returns an HTTP `500` or times out, `order-service` captures the upstream error code inside its JSON `upstream_calls` block and propagates failure status back to `frontend-v1`.
   - If a `Service` port in [`manifests/base-platform.yaml`](./manifests/base-platform.yaml) lacks an explicit protocol prefix (`name: http-api` or `appProtocol: http`), Envoy falls back to protocol sniffing, risking timeouts on server-first protocols and disabling deterministic L7 telemetry until corrected.

### 3.2 Three Production Design Choices Built Into `base-platform.yaml`
1. **Replica Skew (`v1` has 2 replicas, `v2` has 1 replica)**:
   Both `order-service` and `payment-service` run **2 pods of `v1`** and **1 pod of `v2`** behind a single Kubernetes `Service`. Without Istio `VirtualService` rules, traffic splits **66.7% to `v1` and 33.3% to `v2`** purely because of pod count. In [Module 02](../02-service-discovery-and-routing/README.md), you will decouple traffic routing from replica count.
2. **Dedicated `ServiceAccount` per Service (PCI-DSS Requirement)**:
   As Maya Patel (Principal Security Engineer) mandated in `NP-101`, every microservice runs under its own Kubernetes `ServiceAccount` (`frontend-sa`, `order-sa`, `payment-sa`, `inventory-sa`). Istio's Certificate Authority (`istiod`) encodes this into each pod's X.509 certificate SAN as a SPIFFE URI (`spiffe://cluster.local/ns/orderflow/sa/order-sa`), which powers cryptographic mTLS and L7 `AuthorizationPolicy` in Module 04.
3. **Explicit Service Port Naming (`http-web`, `http-api`)**:
   Every Kubernetes `Service` port in [`manifests/base-platform.yaml`](./manifests/base-platform.yaml) uses the `http-<suffix>` naming convention. This disables Envoy's costly protocol sniffing and unlocks full Layer-7 features immediately.

---

## 4. Knowledge Check (Engineering Judgment)

Test your understanding before moving to the hands-on lab.

### Question 1: Legacy `IstioOperator` vs. Official Helm Charts in Istio `1.32.0`
A backend engineer copies a `kind: IstioOperator` YAML file from an old tutorial and opens a Pull Request to deploy Istio `1.32.0` via ArgoCD, expecting an in-cluster operator to reconcile it. Why does Alex reject this PR, and what is the correct installation architecture?

<details>
<summary>Check Answer & Engineering Explanation</summary>

**Answer:**
The **in-cluster `IstioOperator` controller was deprecated in Istio 1.23 and permanently removed in Istio 1.24**, and `kind: IstioOperator` manifests are legacy artifacts that should not be used in modern Istio deployments.
- For both local installations and declarative GitOps reconciliation in ArgoCD or Flux, NovaPay uses the official **Istio Helm charts** (`istio/base`, `istio/istiod`, `istio/cni`, `istio/ztunnel`, `istio/gateway`) with standard Helm `values.yaml` files ([`manifests/helm-values-istiod.yaml`](./manifests/helm-values-istiod.yaml) and [`manifests/helm-values-prod.yaml`](./manifests/helm-values-prod.yaml)).
</details>

### Question 2: Cilium CNI eBPF Socket Load Balancing Conflict
Your Kubernetes `v1.36` cluster uses Cilium CNI with `kubeProxyReplacement=true`. After installing Istio `1.32.0`, you notice that pod-to-pod calls to Kubernetes `Service` ClusterIPs intermittently bypass Envoy's outbound policies or break Ambient Mode `HBONE` tunnels. Which two Cilium settings must be configured and why?

<details>
<summary>Check Answer & Engineering Explanation</summary>

**Answer:**
You must configure:
1. **`cni.exclusive=false`**: Allows `istio-cni` to chain cleanly after Cilium in `/etc/cni/net.d/` so Istio can configure pod network namespaces at sandbox creation.
2. **`socketLB.hostNamespaceOnly=true`**: By default, Cilium's eBPF socket load balancer (`bpf_sockaddr`) hooks the `connect()` syscall inside every pod network namespace and rewrites the destination `Service` ClusterIP to a backend Pod IP *before* the packet enters the Linux network stack where `iptables` or `ztunnel` sockets operate. Restricting `socketLB` to the host namespace ensures packets inside pod network namespaces retain their original `SO_ORIGINAL_DST` ClusterIP for Envoy (`:15001`) and `ztunnel` (`:15008`).
</details>

### Question 3: `ServiceAccount` Identity & Zero-Trust Policy Impact
Why does Maya Patel forbid microservices in `orderflow` from sharing the `default` Kubernetes `ServiceAccount`, even before we write any `AuthorizationPolicy` in Module 04?

<details>
<summary>Check Answer & Engineering Explanation</summary>

**Answer:**
In Istio, workload identity is **not** based on Pod IP or Deployment labels (`app: order-service`) because IPs are ephemeral and labels can be modified by anyone with pod edit permissions. Instead, `istiod` validates the pod's projected `ServiceAccount` JWT and issues an X.509 certificate whose Subject Alternative Name (SAN) is `spiffe://cluster.local/ns/<namespace>/sa/<serviceaccount>`. If `frontend`, `order-service`, and `payment-service` all used the `default` `ServiceAccount`, they would share the identical cryptographic identity (`spiffe://cluster.local/ns/orderflow/sa/default`), making it impossible to restrict `payment-service` to only accept calls from `order-service`.
</details>

---

## 5. Key Takeaways, Definition of Done & Authoritative References

### Key Takeaways
- **Install Istio with Official Helm Charts (`istio/base`, `istio/istiod`, `istio/gateway`)**: Do not use deprecated `IstioOperator` manifests; use declarative Helm `values.yaml` files for both lab and production GitOps environments.
- **Never run `profile=demo` in production**: Its `100%` trace sampling and `10m` CPU requests cause severe proxy throttling under load.
- **Identity starts at the `ServiceAccount` and L7 starts at Port Naming**: Dedicated `ServiceAccounts` establish cryptographic SPIFFE identities, and `http-*`/`grpc-*` port names enable deterministic L7 processing.

### Module 00 Definition of Done
- [ ] You can explain why `profile=demo` and the removed in-cluster `IstioOperator` controller are banned in NovaPay production.
- [ ] Your 4-node multi-zone `kind` cluster (`us-east-1a`, `us-east-1b`, `us-east-1c`) is running Kubernetes `v1.36+` with Gateway API `v1.6.1` Standard CRDs installed.
- [ ] Istio `1.32.0` (`istiod`, `istio-ingressgateway`, `istio-egressgateway`) is running and healthy in `istio-system`.
- [ ] All 9 pods in `orderflow` report `2/2 Running` (`istio-proxy` injected), `legacy-client` in `legacy-uninjected` reports `1/1 Running`, and `istioctl proxy-status` reports `SYNCED` across all proxies.

### Authoritative References
- [Istio 1.32 Installation Guides (Helm & `istioctl`)](https://istio.io/latest/docs/setup/install/)
- [Istio 1.32 Configuration Profiles](https://istio.io/latest/docs/setup/additional-setup/config-profiles/)
- [Istio Application Requirements: Explicit Port Naming & ServiceAccounts](https://istio.io/latest/docs/ops/deployment/application-requirements/)
- [Cilium CNI & Istio Compatibility Configuration](https://istio.io/latest/docs/ambient/install/platform-prerequisites/#cilium)

---

## Next Step
Proceed to [**Module 00 Guided Lab (`LAB.md`)**](./LAB.md) to provision the multi-zone cluster, install Istio `1.32.0`, deploy the `orderflow` platform, and complete the failure-injection troubleshooting challenge.
