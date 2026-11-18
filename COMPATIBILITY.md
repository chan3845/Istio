# Compatibility Matrix & Operational Constraints (`COMPATIBILITY.md`)

This register documents supported component combinations, CNI requirements, API feature parity, and known architectural constraints for **Istio `1.32.0`** in the **NovaPay Service Mesh Engineering Fellowship**.

---

## 1. Istio & Kubernetes Compatibility Matrix

Source: [Istio Supported Releases](https://istio.io/latest/docs/releases/supported-releases/)

| Istio Release | Supported Kubernetes Releases | Bundled Envoy Branch | Tested Gateway API Version | Native Sidecars (`KEP-753`) | Support Status (Nov 2026) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Istio `1.32.x`** *(Fellowship Baseline)* | **`1.33`, `1.34`, `1.35`, `1.36`, `1.37`** | `release/v1.40` | **`v1.6.1`** | GA & Enabled by Default | **Active / Latest Stable** |
| **Istio `1.31.x`** *(Used as N-1 in Week 09)* | `1.32`, `1.33`, `1.34`, `1.35`, `1.36`, `1.37` | `release/v1.39` | `v1.6.1` | GA & Enabled by Default | **Active / Maintenance** |
| **Istio `1.30.x`** | `1.31`, `1.32`, `1.33`, `1.34`, `1.35` | `release/v1.38` | `v1.5.x` | GA & Enabled by Default | **End of Life Approaching** |
| **Istio `<= 1.29`** | `<= 1.34` | `<= v1.37` | `<= v1.4.x` | Beta / GA | **Unsupported (Upgrade Required)** |

---

## 2. CNI Compatibility & Configuration Register

Istio relies on packet redirection inside each Pod's network namespace (either via `istio-init` `iptables`/`nftables`, `istio-cni` chaining, or Ambient in-pod `ztunnel` redirection). How your cluster's primary CNI is configured directly affects whether Istio traffic interception works reliably.

| CNI Provider | Sidecar Mode (`istio-init`) | Sidecar Mode (`istio-cni`) | Ambient Mode (`ztunnel` + `istio-cni`) | Mandatory Configuration & Known Limitations |
| :--- | :--- | :--- | :--- | :--- |
| **`kindnet`** *(Default in `kind`)* | Supported | Supported | Supported | Works out-of-the-box for all fellowship labs (`Week 01`–`Week 10`). |
| **Calico** | Supported | Supported | Supported | If Calico `NetworkPolicy` is enforced, allow traffic to `istiod` ports `15012` (xDS) and `15017` (webhook), plus HBONE port `15008` in Ambient mode. |
| **Cilium (`v1.18+` / `v1.19+`)** | Supported *(with flags)* | Supported *(with flags)* | Supported *(with flags)* | **Critical Conflict Prevention**:<br/>1. **CNI Exclusivity**: Must set `cni.exclusive=false` so Cilium does not overwrite the chained `istio-cni` plugin configuration.<br/>2. **eBPF Socket LB**: When `kubeProxyReplacement=true`, Cilium's in-pod socket LB (`bpf-lb-sock`) rewrites destination sockets before `iptables`/`ztunnel` can intercept them. You **must** set `socketLB.hostNamespaceOnly=true` (`bpf-lb-sock-hostns-only: "true"`). |
| **AWS VPC CNI (EKS)** | Supported | Supported | Supported | Ensure security groups between control-plane nodes and worker nodes permit TCP `15017` (MutatingAdmissionWebhook) and `15012` (xDS). |
| **GKE Dataplane V2** | Supported | Supported | Supported | GKE Dataplane V2 is Cilium-based; on managed GKE clusters, ensure `istio-cni` uses the GKE-specific CNI bin/conf paths (`/home/kubernetes/bin`). |

### Recommended Cilium Helm Values for Istio `1.32` Compatibility
If running fellowship labs on a Cilium-powered cluster without `kube-proxy`, install/upgrade Cilium with:
```bash
helm upgrade cilium cilium/cilium --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set socketLB.hostNamespaceOnly=true \
  --set cni.exclusive=false
```

---

## 3. Classic Istio Networking APIs vs. Kubernetes Gateway API (`v1.6.1`)

Both API families are supported in Istio `1.32.0`. Platform engineers must understand when to use each:

| Capability | Istio Classic API (`Gateway` + `VirtualService`) | Kubernetes Gateway API (`Gateway` + `HTTPRoute` / `GRPCRoute` / `TCPRoute`) | Fellowship Recommendation |
| :--- | :--- | :--- | :--- |
| **North-South Ingress** | Requires pre-deployed `istio-ingressgateway` Pod/Service selected via label. | Declarative `Gateway` resource (`gatewayClassName: istio`) automatically provisions and manages the Envoy deployment & Service. | **Prefer Kubernetes Gateway API** for new ingress deployments (taught alongside Classic `Gateway` in Week 04). |
| **East-West Mesh Routing** | `VirtualService` + `DestinationRule` (`networking.istio.io/v1`). | `HTTPRoute` with `parentRefs` pointing to a Kubernetes `Service` (GAMMA initiative). | **Learn Both**: `VirtualService` + `DestinationRule` remains deeply entrenched in enterprise production; GAMMA `HTTPRoute` is required for Ambient Waypoint L7 routing. |
| **Ambient Mode L7 Waypoints** | *Not supported* (`VirtualService` is not the primary API for Waypoint provisioning). | **Mandatory**: Waypoints are provisioned via `gateway.networking.k8s.io/v1` `Gateway` (`gatewayClassName: istio-waypoint`). | **Mandatory Gateway API** for Ambient Mode (covered in Week 02). |
| **Route-Level `AuthorizationPolicy`** | Matches paths manually inside `AuthorizationPolicy.spec.rules.to.operation.paths`. | **New in Istio `1.32`**: `AuthorizationPolicy` can directly reference an `HTTPRoute` via `targetRefs`! | Covered in Week 04 & Week 05. |

---

## 4. Sidecar Mode vs. Ambient Mode Compatibility (`Istio 1.32`)

| Feature / Scenario | Sidecar Mode (`istio-proxy` per Pod) | Ambient Mode (`ztunnel` L4 + Waypoint L7) | Interoperability in Istio `1.32` |
| :--- | :--- | :--- | :--- |
| **mTLS & L4 `AuthorizationPolicy`** | Enforced by pod's `istio-proxy` (`:15006`). | Enforced by node's `ztunnel` DaemonSet over HBONE (`:15008`). | **Full Interoperability**: Sidecar pods and Ambient pods communicate seamlessly via HBONE mTLS. |
| **L7 Routing, Retries, Fault Injection** | Enforced by client & server `istio-proxy` sidecars. | Enforced by namespace/service **Waypoint Proxy** (`istio-waypoint`). Without a Waypoint, traffic is L4-only. | Supported when Waypoint is deployed for the target namespace/service. |
| **Multi-Network / Mixed Gateways** | Supported. | **Enhanced in Istio `1.32`**: Ambient mode now supports multi-network topologies mixing sidecars and ambient gateways. | Production-ready in `1.32`. |

