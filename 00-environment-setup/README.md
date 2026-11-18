# Module 00: Environment Setup & Reference Microservices Architecture

> **Version & Fellowship Context**
> - **Version Baseline (November 2026)**: Istio `1.32.0` | Envoy `v1.40` | Kubernetes `v1.36+` (Supported: `1.33`–`1.37`) | Gateway API `v1.6.1` — see [`../VERSIONS.md`](../VERSIONS.md) and [`../COMPATIBILITY.md`](../COMPATIBILITY.md).
> - **Fellowship Cohort 01 Mapping**: Complete this module alongside **[Week 01: Platform Onboarding](../fellowship/week-01-platform-onboarding/WEEK.md)**.

Before diving into Istio's internals, we need a realistic Kubernetes cluster and a multi-tier microservices platform that mirrors real enterprise architectures rather than isolated `hello-world` containers.

In this module, you will:
1. Understand how multi-node Kubernetes topology labels (`region`, `zone`), CNI plugins (including **Cilium CNI** compatibility), and NodePort/LoadBalancer mappings interact with Istio `1.32.0`.
2. Compare Istio `1.32.0` installation methods (**Helm charts** for production GitOps vs. **`istioctl install`** with local `IstioOperator` input) and built-in configuration profiles (`default`, `demo`, `minimal`, `ambient`).
3. Deploy the **OrderFlow E-Commerce & Payment Platform**—a 5-service call graph (`frontend` $\rightarrow$ `order-service` $\rightarrow$ `payment-service` & `inventory-service`) that propagates distributed trace headers and returns structured JSON call trees.

---

## 1. Istio 1.32 Installation Methods & Configuration Profiles

### 1.1 Production GitOps (`Helm`) vs. Lab CLI (`istioctl install`)

In Istio `1.32.0`, there are two supported ways to install and upgrade the control plane and data plane components:

| Installation Method | How It Works | Target Environment |
| :--- | :--- | :--- |
| **1. Official Helm Charts (`istio/base`, `istio/istiod`, `istio/cni`, `istio/ztunnel`, `istio/gateway`)** | Standard Helm charts rendered directly by Helm, ArgoCD, or Flux using a declarative `values.yaml` (see [`manifests/helm-values-prod.yaml`](./manifests/helm-values-prod.yaml)). | **Recommended Production & GitOps Standard in Istio 1.32.** Integrates natively with enterprise GitOps pipelines and revision-based canary upgrades. |
| **2. `istioctl install -f <iop.yaml>`** | The `istioctl` CLI compiles a local `IstioOperator` YAML file (see [`manifests/istio-operator-demo-vs-prod.yaml`](./manifests/istio-operator-demo-vs-prod.yaml)) in memory and applies the resulting Kubernetes manifests directly to the API server. | **Interactive Labs, Rapid Prototyping & CLI-Driven Operations.** |

> [!WARNING]
> **Legacy / Historical Context — Removal of the In-Cluster `IstioOperator` Controller (Istio 1.24+)**
> Prior to Istio 1.24, Istio included an optional *in-cluster* `IstioOperator` controller pod that watched `IstioOperator` CRs inside the cluster and mutated the control plane automatically. Because running a privileged controller with cluster-wide RBAC permissions inside the cluster posed security and upgrade risks, the in-cluster `IstioOperator` controller was **deprecated in Istio 1.23 and permanently removed in Istio 1.24**.
>
> In **Istio 1.32.0**, `kind: IstioOperator` (`install.istio.io/v1alpha1`) is strictly a **client-side configuration schema consumed by `istioctl install -f`**. For declarative GitOps reconciliation in production, always use the official **Istio Helm charts** ([`manifests/helm-values-prod.yaml`](./manifests/helm-values-prod.yaml)).

### 1.2 Why Installation Profiles Matter: Learning vs. Production

When running `istioctl install` or setting `profile` in Helm values, Istio applies a built-in **configuration profile** unless overridden. Choosing the wrong profile in production is one of the most common operational mistakes.

| Profile | Components Installed | Key Defaults & Behavior | Target Environment |
| :--- | :--- | :--- | :--- |
| **`default`** | `istiod`, `istio-ingressgateway` (in `istioctl`) | Production-safe defaults, 1% trace sampling, standard resource requests, no egress gateway. | **Production baseline** (customizable via Helm `values.yaml` or `IstioOperator`). |
| **`demo`** | `istiod`, `istio-ingressgateway`, `istio-egressgateway` | 100% trace sampling, verbose access logging, minimal CPU/memory requests (`10m` CPU). | **Never use in production.** High trace sampling and tiny resource requests cause CPU throttling under load. |
| **`minimal`** | `istiod` only | Control plane only; gateways are deployed separately as standalone workloads. | **Enterprise GitOps** where gateways are managed by separate teams/namespaces or Kubernetes Gateway API. |
| **`ambient`** | `istiod`, `istio-cni`, `ztunnel` | Enables sidecarless Ambient Data Plane mode (`ztunnel` L4 DaemonSet + `istio-cni`). | **Ambient Mesh deployments** (covered in Module 01). |

### 1.3 Cilium CNI Compatibility Requirements (Istio 1.32 Sidecar & Ambient Modes)

If your Kubernetes `v1.36+` cluster runs **Cilium CNI** (especially with eBPF `kubeProxyReplacement=true`), you **must** configure two critical Cilium settings so Cilium's eBPF programs do not bypass Istio's `istio-cni` netns redirection (`ztunnel`) or Envoy `iptables` socket interception:

1. **`cni.exclusive=false`**: Allows `istio-cni` to chain cleanly after Cilium in `/etc/cni/net.d/` so Istio can hook pod network namespaces at pod startup.
2. **`socketLB.hostNamespaceOnly=true`**: Restricts Cilium's eBPF socket-level load balancing (`bpf_sockaddr`) to the host network namespace only. Without this setting, Cilium rewrites Service ClusterIPs inside the pod's socket layer *before* packets ever reach Envoy (`:15001`) or `ztunnel` (`:15008`), breaking Istio mTLS, L7 routing, and Ambient HBONE tunnels!

### Our Course Approach
Instead of blindly installing `--set profile=demo`, we provide both a production Helm configuration in [`manifests/helm-values-prod.yaml`](./manifests/helm-values-prod.yaml) and a customized `default`-derived `IstioOperator` specification in [`manifests/istio-operator-demo-vs-prod.yaml`](./manifests/istio-operator-demo-vs-prod.yaml) that explicitly configures each setting (`accessLogFile`, `ISTIO_META_DNS_CAPTURE`, `extensionProviders`, `egressGateways`) so you see exactly which knobs control Istio's runtime behavior.

---

## 2. The "OrderFlow" Reference Microservices Architecture

Throughout Modules 01–08, we use the **OrderFlow** platform in the `orderflow` namespace. Every service runs `nicholasjackson/fake-service`, a purpose-built microservice simulator used in production service mesh benchmarks that:
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

### Key Architectural Details to Notice
1. **Replica Skew (`v1` has 2 replicas, `v2` has 1 replica)**:
   Both `order-service` and `payment-service` have **2 pods of `v1`** and **1 pod of `v2`** behind a single Kubernetes `Service`. Without Istio `VirtualService` rules, traffic splits **66.7% to `v1` and 33.3% to `v2`** purely because of pod count! In Module 02, you will decouple traffic routing from replica count.
2. **Dedicated `ServiceAccount` per Service**:
   Every microservice runs under its own Kubernetes `ServiceAccount` (`frontend-sa`, `order-sa`, `payment-sa`, `inventory-sa`). Istio's Certificate Authority (`istiod`) encodes this into each pod's X.509 certificate SAN as a SPIFFE URI (`spiffe://cluster.local/ns/orderflow/sa/order-sa`), which powers cryptographic mTLS and L7 `AuthorizationPolicy` in Module 04.
3. **Explicit Service Port Naming (`http-web`, `http-api`)**:
   Every Kubernetes `Service` port in [`base-platform.yaml`](./manifests/base-platform.yaml) uses the `http-<suffix>` naming convention. This disables Envoy's costly protocol sniffing and unlocks full Layer-7 features immediately.

---

## Next Step
Proceed to [**LAB.md**](./LAB.md) to provision the cluster, install Istio, deploy the OrderFlow platform, and verify end-to-end call graphs.

