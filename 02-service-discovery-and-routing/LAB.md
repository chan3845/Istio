[Fellowship Portal](../README.md) | [Week 03 Guide](../fellowship/week-03-service-discovery-and-l7-routing/WEEK.md) | [Module 02 Hub (README.md)](./README.md) | [<- Lesson 02.3](./lessons/03-load-balancing-and-sidecar-scoping.md) | [Next: Module 03 ->](../03-gateways-ingress-and-egress/README.md)

# Module 02 Lab: Traffic Routing, Subsets, Consistent Hashing, `Sidecar` Scoping & The `503 NR` Trap

> [!NOTE]
> **Execution Verification Status**
> *Statically validated against Istio `1.32.0` / Kubernetes `v1.36+` schemas. Execute the Pre-Flight and Verification steps below on your local `kind` cluster to verify runtime behavior.*

## Lab Metadata & Learning Objectives
- **Estimated Completion Time**: `45 mins`
- **Engineering Ticket Alignment**: **[Week 03 Ticket `NP-103` & Incident `INC-03`](../fellowship/week-03-service-discovery-and-l7-routing/WEEK.md)**
- **Learning Objectives**:
  1. Observe default load balancing across `v1` and `v2` pods when no `DestinationRule` or `VirtualService` is present.
  2. Define `DestinationRule` subsets (`v1` and `v2`) and verify how Envoy `v1.40` creates dedicated subset clusters in `CDS`.
  3. Implement L7 header-based routing (`x-user-tier: vip` $\rightarrow$ `payment-service` `v2`), weighted canary traffic splitting (`80%` `v1` / `20%` `v2` for `order-service`), and URI prefix rewriting (`/api/orders` $\rightarrow$ `/`).
  4. Configure session affinity using `consistentHash` (`RING_HASH`) on an HTTP header (`x-session-id`).
  5. Scope Envoy's configuration footprint using the `Sidecar` CRD and measure the exact reduction in Envoy clusters.
  6. Reproduce, diagnose, and fix the notorious **`503 NR` (`No Route` / Missing Subset) Evaluation Order Trap (`INC-03`)**.

---

## Prerequisites & Version Baseline Pre-Flight Verification

> **Version Baseline (November 2026)**: Istio `1.32.0` | Envoy `v1.40` | Kubernetes `v1.36+` | Gateway API `v1.6.1`
> **Fellowship Reference**: **[Week 03: Service Discovery & L7 Traffic Routing](../fellowship/week-03-service-discovery-and-l7-routing/WEEK.md)** | [`../VERSIONS.md`](../VERSIONS.md)

- Kubernetes `v1.36+` cluster with Istio `1.32.0` installed and the `orderflow` namespace running from Module 00/01.
- Verify the Istio control plane version and clean up any leftover routing rules in `orderflow` before starting:
  ```bash
  istioctl version
  kubectl delete virtualservice,destinationrule,sidecar --all -n orderflow
  ```

---

## Architecture & Expected Traffic Flow

```mermaid
flowchart LR
    Client["client-toolbox / frontend"] -->|"GET /api/orders"| VS_Order["VirtualService: order-service<br/>1. Rewrite /api/orders -> /<br/>2. Split 80% v1 / 20% v2"]
    
    VS_Order -->|"80%"| OrderV1["order-service (v1)"]
    VS_Order -->|"20%"| OrderV2["order-service (v2)"]

    OrderV1 --> VS_Pay["VirtualService: payment-service"]
    OrderV2 --> VS_Pay

    VS_Pay -->|"Header x-user-tier: vip"| PayV2["payment-service (v2)<br/>(VIP Fast Track)"]
    VS_Pay -->|"Default (All other requests)"| PayV1["payment-service (v1)<br/>(Standard Tier)"]

    OrderV1 --> InvV1["inventory-service (v1)"]
    OrderV2 --> InvV1
```

---

## Step-by-Step Implementation

### Step 1: Observe Baseline Routing Without `VirtualService` or `DestinationRule`

When no `VirtualService` or `DestinationRule` exists, Envoy routes all traffic for `order-service` to the single default cluster `outbound|8080||order-service.orderflow.svc.cluster.local`, which contains endpoints for **both** `v1` (2 replicas) and `v2` (1 replica) pods.

> [!TIP]
> **Predict Before You Execute (Baseline Replica Distribution)**
> Before running the 6 test requests and `istioctl proxy-config cluster` below:
> 1. What value will appear in the `SUBSET` column of `istioctl proxy-config cluster` for `order-service` and `payment-service` right now?
> 2. Why do both `v1` and `v2` respond even though we haven't created any Istio routing rules yet?

Run 6 requests from `client-toolbox` to `order-service` and inspect which versions of `order-service` and `payment-service` respond:

```bash
TOOLBOX_POD=$(kubectl get pod -n orderflow -l app=client-toolbox -o jsonpath='{.items[0].metadata.name}')

for i in $(seq 1 6); do
  kubectl exec -n orderflow "$TOOLBOX_POD" -c toolbox -- curl -s http://order-service:8080 | grep -E '"name":|"body":'
  echo "---"
done
```

**Expected Output:**
You will see a mix of `order-service-v1` (~67%) and `order-service-v2` (~33%), calling a mix of `payment-service-v1` and `payment-service-v2`:
```text
  "name": "order-service-v1",
  "body": "Order Processing Engine v1 (Standard)",
      "name": "payment-service-v2",
      "body": "Payment Gateway Adapter v2 (Multi-Currency Canary)",
---
  "name": "order-service-v2",
  "body": "Order Processing Engine v2 (Fast-Checkout Canary)",
      "name": "payment-service-v1",
      "body": "Payment Gateway Adapter v1 (Standard)",
```

Check the clusters currently configured on `client-toolbox` for `order-service` and `payment-service`:

```bash
istioctl proxy-config cluster "$TOOLBOX_POD.orderflow" | grep -E "order-service|payment-service"
```

**Expected Output:**
```text
 order-service.orderflow.svc.cluster.local      8080  -      outbound  EDS
 payment-service.orderflow.svc.cluster.local    8080  -      outbound  EDS
```
Notice the `SUBSET` column is `-` (only the default cluster exists).

---

### Step 2: Apply `DestinationRule` Subsets First (Safe Rollout Pattern)

Now apply [`manifests/destination-rules.yaml`](./manifests/destination-rules.yaml), which defines `v1` and `v2` subsets for both `order-service` and `payment-service`:

```bash
kubectl apply -f 02-service-discovery-and-routing/manifests/destination-rules.yaml
```

> [!TIP]
> **Predict Before You Execute (`CDS` Subset Creation)**
> After applying `destination-rules.yaml` (which defines subsets `v1` and `v2` for `order-service` and `payment-service`):
> - How many total clusters for `order-service` will now exist in `istioctl proxy-config cluster` (`2` or `3`)?
> - If you call `http://order-service:8080` right now (before applying a `VirtualService`), which of those clusters will Envoy actually use?

Inspect the Envoy clusters on `client-toolbox` again:

```bash
istioctl proxy-config cluster "$TOOLBOX_POD.orderflow" | grep -E "order-service|payment-service"
```

**Expected Output:**
```text
SERVICE FQDN                                   PORT  SUBSET  DIRECTION  TYPE  DESTINATION RULE
order-service.orderflow.svc.cluster.local      8080  -       outbound   EDS   order-service-dr.orderflow
order-service.orderflow.svc.cluster.local      8080  v1      outbound   EDS   order-service-dr.orderflow
order-service.orderflow.svc.cluster.local      8080  v2      outbound   EDS   order-service-dr.orderflow
payment-service.orderflow.svc.cluster.local    8080  -       outbound   EDS   payment-service-dr.orderflow
payment-service.orderflow.svc.cluster.local    8080  v1      outbound   EDS   payment-service-dr.orderflow
payment-service.orderflow.svc.cluster.local    8080  v2      outbound   EDS   payment-service-dr.orderflow
```

Verify that each subset cluster (`v1` vs `v2`) only contains the Pod IPs matching its label selector (`version: v1` vs `version: v2`):

```bash
istioctl proxy-config endpoint "$TOOLBOX_POD.orderflow" --cluster "outbound|8080|v1|order-service.orderflow.svc.cluster.local"
istioctl proxy-config endpoint "$TOOLBOX_POD.orderflow" --cluster "outbound|8080|v2|order-service.orderflow.svc.cluster.local"
```

---

### Step 3: Apply `VirtualService` for Canary Splits, Header Routing & URI Rewrites

Now that the subset clusters exist in `CDS` and their endpoints are populated in `EDS`, apply [`manifests/virtual-services-routing.yaml`](./manifests/virtual-services-routing.yaml):

```bash
kubectl apply -f 02-service-discovery-and-routing/manifests/virtual-services-routing.yaml
```

Let's review what `virtual-services-routing.yaml` configures:
1. **`order-service-vs`**:
   - Rewrites URI prefix `/api/orders` to `/` so callers can request `/api/orders` while `order-service` receives `/`.
   - Splits traffic **80% to `v1`** and **20% to `v2`**.
2. **`payment-service-vs`**:
   - If HTTP header `x-user-tier: vip` is present, routes **100% to `v2`**.
   - Otherwise, routes **100% to `v1`**.

#### 3.1 Verify URI Rewrite and 80/20 Weighted Canary Split on `order-service`

Call `http://order-service:8080/api/orders` 10 times from `client-toolbox`:

```bash
for i in $(seq 1 10); do
  kubectl exec -n orderflow "$TOOLBOX_POD" -c toolbox -- curl -s http://order-service:8080/api/orders | grep -m 1 '"name":'
done
```

**Expected Output:**
Approximately 8 responses from `order-service-v1` and 2 responses from `order-service-v2`:
```text
  "name": "order-service-v1",
  "name": "order-service-v1",
  "name": "order-service-v2",
  "name": "order-service-v1",
  "name": "order-service-v1",
  "name": "order-service-v1",
  "name": "order-service-v1",
  "name": "order-service-v2",
  "name": "order-service-v1",
  "name": "order-service-v1",
```

#### 3.2 Verify Header-Based Routing (`x-user-tier: vip`) to `payment-service`

First, call `payment-service` without the header (should always hit `payment-service-v1`):

```bash
for i in $(seq 1 5); do
  kubectl exec -n orderflow "$TOOLBOX_POD" -c toolbox -- curl -s http://payment-service:8080 | grep '"name":'
done
```

**Expected Output:**
```text
  "name": "payment-service-v1",
  "name": "payment-service-v1",
  "name": "payment-service-v1",
  "name": "payment-service-v1",
  "name": "payment-service-v1",
```

Now pass `-H "x-user-tier: vip"` (should always hit `payment-service-v2`):

```bash
for i in $(seq 1 5); do
  kubectl exec -n orderflow "$TOOLBOX_POD" -c toolbox -- curl -s -H "x-user-tier: vip" http://payment-service:8080 | grep '"name":'
done
```

**Expected Output:**
```text
  "name": "payment-service-v2",
  "name": "payment-service-v2",
  "name": "payment-service-v2",
  "name": "payment-service-v2",
  "name": "payment-service-v2",
```

Inspect the Envoy `RDS` route configuration on `client-toolbox` to see how `x-user-tier: vip` was compiled into Envoy's route table:

```bash
istioctl proxy-config route "$TOOLBOX_POD.orderflow" --name 8080 -o json | grep -A 25 '"name": "vip-fast-track"'
```

---

### Step 4: Test Session Affinity with `consistentHash` Load Balancing

Suppose `order-service` has multiple pod endpoints (`v1` and `v2`) and we want every request with the same `x-session-id` header to consistently hit the **exact same pod endpoint**.

Apply [`manifests/consistent-hash-lb.yaml`](./manifests/consistent-hash-lb.yaml):

```bash
kubectl apply -f 02-service-discovery-and-routing/manifests/consistent-hash-lb.yaml
```

Inspect the cluster load balancer type in Envoy (`RING_HASH`):

```bash
istioctl proxy-config cluster "$TOOLBOX_POD.orderflow" --fqdn order-service.orderflow.svc.cluster.local -o json | grep -E '"name":|"lbPolicy":'
```

**Expected Output:**
```json
        "name": "outbound|8080||order-service.orderflow.svc.cluster.local",
        "lbPolicy": "RING_HASH",
```

Test sending 5 requests with `x-session-id: user-alpha-101` — notice that every single request lands on the exact same backend pod IP and version:

```bash
for i in $(seq 1 5); do
  kubectl exec -n orderflow "$TOOLBOX_POD" -c toolbox -- curl -s -H "x-session-id: user-alpha-101" http://order-service:8080 | grep -m 2 -E '"name":|"ip_addresses":' -A 1
done
```

Restore the standard `destination-rules.yaml` and `virtual-services-routing.yaml` after testing:

```bash
kubectl apply -f 02-service-discovery-and-routing/manifests/destination-rules.yaml
kubectl apply -f 02-service-discovery-and-routing/manifests/virtual-services-routing.yaml
```

---

### Step 5: Scope Envoy Memory & xDS Push Size with the `Sidecar` Resource

First, count how many total clusters Envoy in `client-toolbox` is currently tracking across the entire Kubernetes cluster (including `kube-system`, `default`, `legacy-uninjected`, etc.):

```bash
istioctl proxy-config cluster "$TOOLBOX_POD.orderflow" | wc -l
```

Look at the services outside `orderflow` that `client-toolbox` knows about (e.g., `kubernetes.default.svc.cluster.local`, `kube-dns.kube-system.svc.cluster.local`):

```bash
istioctl proxy-config cluster "$TOOLBOX_POD.orderflow" | grep -v "orderflow"
```

> [!TIP]
> **Predict Before You Execute (`Sidecar` xDS Pruning)**
> When we apply [`manifests/sidecar-scope.yaml`](./manifests/sidecar-scope.yaml) (which sets `egress.hosts: ["./*", "istio-system/*"]`):
> - What will happen to `kubernetes.default.svc.cluster.local` and `kube-dns.kube-system.svc.cluster.local` in `client-toolbox`'s `istioctl proxy-config cluster` output?

Now apply [`manifests/sidecar-scope.yaml`](./manifests/sidecar-scope.yaml):

```bash
kubectl apply -f 02-service-discovery-and-routing/manifests/sidecar-scope.yaml
```

Re-run the cluster count and filter check:

```bash
istioctl proxy-config cluster "$TOOLBOX_POD.orderflow" | wc -l
istioctl proxy-config cluster "$TOOLBOX_POD.orderflow" | grep -v "orderflow"
```

**Expected Output:**
All clusters from `default`, `kube-system`, and other unrelated namespaces have been completely pruned from Envoy's memory! Only `orderflow`, `istio-system`, and Envoy internal clusters (`BlackHoleCluster`, `PassthroughCluster`, `InboundPassthroughClusterIpv4`, `xds-grpc`) remain.

---

## Step 6: Troubleshooting Exercise — Reproduce & Fix the `503 NR` Missing Subset Bug (`INC-03`)

Let's intentionally trigger the **Evaluation Order / Missing Subset Trap (`INC-03`)** by applying [`manifests/broken-subset-trap.yaml`](./manifests/broken-subset-trap.yaml), which routes `inventory-service` traffic to `subset: v2-canary` — a subset that does not exist in any `DestinationRule`!

```bash
kubectl apply -f 02-service-discovery-and-routing/manifests/broken-subset-trap.yaml
```

Now call `inventory-service` from `client-toolbox` with `-i` to see the HTTP response status:

```bash
kubectl exec -n orderflow "$TOOLBOX_POD" -c toolbox -- curl -i -s http://inventory-service:8080
```

**Expected Output:**
```http
HTTP/1.1 503 Service Unavailable
date: Tue, 17 Nov 2026 16:10:00 GMT
server: envoy
content-length: 0
```

### Your Challenge
Diagnose why `inventory-service` is failing with `503 Service Unavailable`, verify the exact Envoy response flag and control plane analyzer error code, and restore `200 OK` traffic. Try to solve it before opening the progressive hints below!

<details>
<summary>Hint 1: Where to look</summary>

Compare the target `cluster` referenced inside Envoy's `Route: 8080` (`RDS`) for `inventory-service.orderflow.svc.cluster.local:8080` against the actual clusters present in Envoy's `CDS` table (`istioctl proxy-config cluster`). Also try running Istio's static configuration analyzer on the `orderflow` namespace.
</details>

<details>
<summary>Hint 2: Diagnostic commands</summary>

Run these three commands:
```bash
# 1. Static Control Plane Analyzer
istioctl analyze -n orderflow

# 2. Check the Route (RDS) target cluster for inventory-service
istioctl proxy-config route "$TOOLBOX_POD.orderflow" --name 8080 -o json | grep "v2-canary"

# 3. Check if that subset cluster exists in CDS
istioctl proxy-config cluster "$TOOLBOX_POD.orderflow" | grep "inventory-service"
```
</details>

<details>
<summary>Full Explanation & Solution</summary>

**Root Cause:**
1. `istioctl analyze -n orderflow` reports:
   `Error [IST0101] (VirtualService orderflow/inventory-service-broken-vs) Referenced host+subset in destinationrule not found: "inventory-service.orderflow.svc.cluster.local+v2-canary"`
2. In Envoy's `RDS` route table (`Route: 8080`), the route for `inventory-service` points to cluster `outbound|8080|v2-canary|inventory-service.orderflow.svc.cluster.local`.
3. In Envoy's `CDS` cluster table, only `outbound|8080||inventory-service.orderflow.svc.cluster.local` exists because no `DestinationRule` defines `subset: v2-canary`. Envoy therefore rejects every request with `HTTP 503` (`Response Flag: NR`).

**Fix:**
Either create a `DestinationRule` defining `subset: v2-canary` first, or delete the broken `VirtualService` so traffic falls back to the default `inventory-service` cluster:
```bash
kubectl delete -f 02-service-discovery-and-routing/manifests/broken-subset-trap.yaml
kubectl exec -n orderflow "$TOOLBOX_POD" -c toolbox -- curl -i -s http://inventory-service:8080 | head -n 10
```
`inventory-service` immediately returns `HTTP/1.1 200 OK`!
</details>

---

## Step 7: Cleanup / Reset Procedure

Before moving to Module 03, verify that `broken-subset-trap.yaml` is deleted. You may either keep the baseline `destination-rules.yaml`, `virtual-services-routing.yaml`, and `sidecar-scope.yaml` active or reset `orderflow` to a clean slate with:

```bash
kubectl delete -f 02-service-discovery-and-routing/manifests/broken-subset-trap.yaml --ignore-not-found
kubectl delete -f 02-service-discovery-and-routing/manifests/consistent-hash-lb.yaml --ignore-not-found
kubectl apply -f 02-service-discovery-and-routing/manifests/destination-rules.yaml
kubectl apply -f 02-service-discovery-and-routing/manifests/virtual-services-routing.yaml
kubectl apply -f 02-service-discovery-and-routing/manifests/sidecar-scope.yaml
istioctl analyze -n orderflow
```

Confirm `istioctl analyze -n orderflow` reports `✔ No validation issues found when analyzing namespace: orderflow.`.

---

## Production Considerations (Alex, Sarah & Maya's Checklist)

1. **Enforce `istioctl analyze` as a Mandatory CI/CD Gate**:
   Every `503 NR` missing-subset outage (`IST0101`) can be caught *before* merging a Pull Request by running `istioctl analyze --use-kube=false -f manifests/` in CI pipelines.
2. **Use GitOps Sync Waves (`DestinationRule` Wave 1 $\rightarrow$ `VirtualService` Wave 2)**:
   In ArgoCD or Flux, annotate `DestinationRule` resources with `argocd.argoproj.io/sync-wave: "1"` and `VirtualService` resources with `argocd.argoproj.io/sync-wave: "2"` so subset clusters (`CDS`) are always created and populated before routes (`RDS`) reference them.
3. **Set `exportTo: ["."]` on Private Routing Rules**:
   By default, a `VirtualService` or `DestinationRule` is exported to all namespaces (`exportTo: ["*"]`). Add `spec.exportTo: ["."]` on namespace-internal routing rules so they do not bloat `istiod` compilation or collide across namespaces.

---

## Next Step
Proceed to **[Module 03: Gateways, Kubernetes Gateway API `v1.6.1` & Traffic Entry/Exit (`ServiceEntry`) ->](../03-gateways-ingress-and-egress/README.md)**!
