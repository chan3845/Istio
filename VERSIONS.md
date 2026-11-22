# Authoritative Version Baseline & Governance (`VERSIONS.md`)

This document establishes the authoritative software version baseline for the **Istio Service Mesh Engineering Fellowship — Cohort 01**. All modules, hands-on labs, Kubernetes manifests, `istioctl` commands, expected outputs, and troubleshooting exercises in this repository target this baseline.

---

## 1. Selected Version Baseline (November 2026)

| Component | Selected Version | Release / Channel Status | Role in the Fellowship |
| :--- | :--- | :--- | :--- |
| **Istio Service Mesh** | **`1.32.0`** *(N-1: `1.31.x`)* | Latest Stable Release (Released Nov 9, 2026) | Control plane (`istiod`), sidecar proxy (`istio-proxy`), Ambient L4 node proxy (`ztunnel`), and `istio-cni`. `1.31.x` is used as the N-1 baseline during Week 09 canary upgrade labs. |
| **Envoy Proxy** | **`1.40.x`** (`release/v1.40`) | Bundled with Istio `1.32.x` (`istio/proxy`) | Data plane proxy for Sidecar Mode, Ingress/Egress Gateways, and Ambient L7 Waypoint proxies. |
| **Kubernetes** | **`1.36.x` / `1.37.x`** *(Supported: `1.33` – `1.37`)* | Latest Stable Releases | Underlying container orchestration platform. Native Sidecar Containers (`KEP-753`, GA in K8s `1.33+`) are enabled by default. |
| **Kubernetes Gateway API** | **`v1.6.1`** (`standard-install.yaml`) | Latest Stable Standard Channel | Declarative North-South ingress (`GatewayClass`, `Gateway`, `HTTPRoute`, `GRPCRoute`, `TCPRoute`, `UDPRoute`) and Ambient Waypoint provisioning. |
| **Cilium CNI** *(when used)* | **`1.18+` / `1.19+`** | Stable Production CNI | eBPF CNI. Requires `cni.exclusive=false` and `socketLB.hostNamespaceOnly=true` when `kubeProxyReplacement=true`. |
| **Kind (Local Cluster)** | **`v0.33.0+`** | Stable Local Lab Runtime | Multi-node local Kubernetes cluster for executing fellowship labs. |
| **Helm** | **`v3.16+`** | Stable Package Manager | Recommended production and GitOps installation mechanism for Istio charts (`base`, `istiod`, `cni`, `ztunnel`, `gateway`). |
| **Reference App (`fake-service`)** | **`v0.26.2`** | Stable Benchmark Workload | Simulates NovaPay's `orderflow` and `novapay` multi-tier HTTP/gRPC services with automatic W3C `traceparent` and B3 header propagation. |

---

## 2. Istio CRD API Version Baseline

Every Istio configuration manifest in this repository uses the **stable `v1` API versions**:

| API Group | Version | Resources Covered | Status in Istio `1.32` |
| :--- | :--- | :--- | :--- |
| **`networking.istio.io/v1`** | `v1` | `VirtualService`, `DestinationRule`, `Gateway`, `ServiceEntry`, `Sidecar`, `WorkloadEntry`, `WorkloadGroup` | **GA / Stable** (`v1alpha3` and `v1beta1` are legacy aliases; all fellowship manifests use `v1`). |
| **`security.istio.io/v1`** | `v1` | `PeerAuthentication`, `RequestAuthentication`, `AuthorizationPolicy` | **GA / Stable** (Includes Istio `1.32` support for targeting Gateway API `HTTPRoute` via `targetRefs`). |
| **`telemetry.istio.io/v1`** | `v1` | `Telemetry` | **GA / Stable** (Replaces legacy `meshConfig` metric/trace patching and `EnvoyFilter` telemetry hacks). |
| **`gateway.networking.k8s.io/v1`** | `v1` | `GatewayClass`, `Gateway`, `HTTPRoute`, `GRPCRoute`, `TCPRoute`, `UDPRoute` | **GA / Standard Channel (`v1.6.1`)** (`TCPRoute` and `UDPRoute` graduated to Standard in Gateway API `v1.6`). |

> **Deprecated / Removed API Notice (`IstioOperator`)**:
> The in-cluster `IstioOperator` controller (`install.istio.io/v1alpha1`) was deprecated in Istio `1.23` and permanently removed in Istio `1.24`. This fellowship uses **zero** `kind: IstioOperator` manifests; all control-plane and gateway installations use the **official Istio Helm charts** (`istio/base`, `istio/istiod`, `istio/cni`, `istio/ztunnel`, `istio/gateway`) with declarative Helm `values.yaml` files.

---

## 3. Pre-Flight Environment Verification Command

Every lab in this fellowship assumes your environment matches the version baseline above. Run this verification snippet before starting any lab:

```bash
echo "=== Kubernetes Client & Server Version (Expected: K8s 1.33 - 1.37) ==="
kubectl version

echo "=== Istio CLI & Control Plane Version (Expected: 1.32.x) ==="
istioctl version

echo "=== Gateway API CRDs (Expected: v1.6.1 Standard Channel) ==="
kubectl get crd gateways.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}{"\n"}'
```

> **Execution Verification Policy**:
> All YAML manifests in this repository have been statically validated for syntax and Istio `v1` / Kubernetes `v1` schema compliance. Because this repository is distributed as source files and your local machine may not yet have `istioctl 1.32.0` or a running `kind` cluster active during reading, labs include exact **Pre-Flight Verification** and **Post-Implementation Validation (`istioctl analyze`, `istioctl proxy-status`)** steps so you can execution-verify every exercise on your own cluster.

---

## 4. Authoritative References

1. **Istio Official Documentation (`1.32`)**: https://istio.io/latest/docs/
2. **Istio Release Announcements (`1.32.0` & `1.31.0`)**: https://istio.io/latest/news/releases/
3. **Istio Supported Releases & Kubernetes Compatibility Matrix**: https://istio.io/latest/docs/releases/supported-releases/
4. **Istio GitHub Repository**: https://github.com/istio/istio
5. **Envoy Proxy Documentation (`v1.40`)**: https://www.envoyproxy.io/docs/envoy/latest/
6. **Kubernetes Official Documentation (`v1.37`)**: https://kubernetes.io/docs/
7. **Kubernetes Gateway API (`v1.6.1`)**: https://gateway-api.sigs.k8s.io/
8. **Cilium Istio Integration Guide**: https://docs.cilium.io/

