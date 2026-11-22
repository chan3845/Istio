[Fellowship Portal](../README.md) | [Week 01 Guide](../fellowship/week-01-platform-onboarding/WEEK.md) | [Module 00 Architecture (README.md)](./README.md) | [Next: Module 01 ->](../01-architecture-and-internals/README.md)

# Lab 00: Provisioning the NovaPay Multi-Zone Cluster, Installing Istio `1.32.0`, and Deploying `OrderFlow`

> [!NOTE]
> **Execution Verification Status**
> *Statically validated against Istio `1.32.0` / Kubernetes `v1.36+` schemas. Execute the Pre-Flight and Verification steps below on your local `kind` cluster to verify runtime behavior.*

## Lab Metadata & Learning Objectives
- **Estimated Completion Time**: `30 mins`
- **Engineering Ticket Alignment**: **[Week 01 Ticket `NP-101` & Incident `INC-01`](../fellowship/week-01-platform-onboarding/WEEK.md)**
- **Learning Objectives**:
  1. Provision a multi-node, multi-zone Kubernetes `v1.36+` cluster using `kind` across `us-east-1a`, `us-east-1b`, and `us-east-1c`.
  2. Install Istio `1.32.0` (`istio-base`, `istiod`, `istio-ingressgateway`, `istio-egressgateway`) using the **official Istio Helm charts** and modular `values.yaml` files alongside Kubernetes Gateway API `v1.6.1` Standard CRDs.
  3. Verify how namespace labels (`istio-injection=enabled`) trigger automatic Envoy `v1.40` sidecar injection.
  4. Deploy the NovaPay `OrderFlow` microservices platform, predict and inspect its multi-hop JSON call graph, and resolve an uninjected workload failure mode.

---

## Prerequisites & Version Baseline (November 2026)

> **Authoritative Version Baseline**:
> - **Istio**: `1.32.0` (Envoy Proxy `v1.40`)
> - **Kubernetes**: `v1.36+` (Supported window for Istio `1.32.0`: `v1.33` – `v1.37`)
> - **Kubernetes Gateway API**: `v1.6.1` (Standard channel — includes graduated `TCPRoute` and `UDPRoute`)
> - **Fellowship Reference**: **[Week 01: Platform Onboarding](../fellowship/week-01-platform-onboarding/WEEK.md)** | [`../VERSIONS.md`](../VERSIONS.md)

Ensure the following CLI tools are installed on your workstation:
- `docker` (running and accessible)
- `kubectl` (`v1.36+`)
- `kind` (`v0.27+` — if running locally)
- `istioctl` (`v1.32.0`)
- `helm` (`v3.17+` — for production Helm chart installation)
- `jq` and `openssl` (for inspecting JSON outputs and TLS certificates)

---

## Step 1: Create the Multi-Node Kubernetes Cluster

Apply the `kind` configuration in [`manifests/kind-cluster.yaml`](./manifests/kind-cluster.yaml) to create a 4-node cluster (1 control-plane + 3 workers across `us-east-1a`, `us-east-1b`, and `us-east-1c`):

```bash
kind create cluster --config 00-environment-setup/manifests/kind-cluster.yaml
```

Verify the nodes and their topology zone labels:

```bash
kubectl get nodes -L topology.kubernetes.io/region,topology.kubernetes.io/zone,workload-tier
```

**Expected Output:**
```text
NAME                         STATUS   ROLES           AGE   VERSION   REGION      ZONE         WORKLOAD-TIER
istio-course-control-plane   Ready    control-plane   45s   v1.36.0   <none>      <none>       <none>
istio-course-worker          Ready    <none>          25s   v1.36.0   us-east-1   us-east-1a   general
istio-course-worker2         Ready    <none>          25s   v1.36.0   us-east-1   us-east-1b   general
istio-course-worker3         Ready    <none>          25s   v1.36.0   us-east-1   us-east-1c   pci
```

---

## Step 2: Run Pre-Check and Install Istio `1.32.0` via Official Helm Charts

Before installing Istio, always verify cluster compatibility with `istioctl x precheck`:

```bash
istioctl x precheck
```

**Expected Output:**
```text
✔ No issues found when checking the cluster. Istio is safe to install or upgrade!
```

Now install Istio `1.32.0` using the **official Istio Helm charts** (`istio/base`, `istio/istiod`, and `istio/gateway`) and our modular Helm values files in [`00-environment-setup/manifests/`](./manifests/) (note: for production HA clusters, compare [`manifests/helm-values-istiod.yaml`](./manifests/helm-values-istiod.yaml) against [`manifests/helm-values-prod.yaml`](./manifests/helm-values-prod.yaml)):

```bash
# 1. Add and update the official Istio Helm repository
# (Note: The legacy GCP bucket istio-release.storage.googleapis.com/charts is decommissioned;
#  always use the current official endpoint https://blob.istio.io/istio-release/charts)
helm repo add istio https://blob.istio.io/istio-release/charts --force-update
helm repo update

# 2. Install istio-base (Cluster-wide CRDs and cluster roles)
helm upgrade --install istio-base istio/base \
  -n istio-system --create-namespace \
  --version 1.32.0 \
  --set defaultRevision=default \
  --wait

# 3. Install istiod (Control Plane) using our lab Helm values
helm upgrade --install istiod istio/istiod \
  -n istio-system \
  --version 1.32.0 \
  -f 00-environment-setup/manifests/helm-values-istiod.yaml \
  --wait

# 4. Install istio-ingressgateway and istio-egressgateway using the istio/gateway chart
helm upgrade --install istio-ingressgateway istio/gateway \
  -n istio-system \
  --version 1.32.0 \
  -f 00-environment-setup/manifests/helm-values-ingressgateway.yaml \
  --wait

helm upgrade --install istio-egressgateway istio/gateway \
  -n istio-system \
  --version 1.32.0 \
  -f 00-environment-setup/manifests/helm-values-egressgateway.yaml \
  --wait
```

Verify the installed Helm releases and confirm that `istiod`, `istio-ingressgateway`, and `istio-egressgateway` are running in `istio-system`:

```bash
helm list -n istio-system
kubectl get pods,svc -n istio-system
```

**Expected Output:**
```text
NAME                                        READY   STATUS    RESTARTS   AGE
pod/istio-egressgateway-xxxx                1/1     Running   0          30s
pod/istio-ingressgateway-xxxx               1/1     Running   0          30s
pod/istiod-xxxx                             1/1     Running   0          45s

NAME                           TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)                                      AGE
service/istio-egressgateway    ClusterIP   10.96.114.201   <none>        80/TCP,443/TCP                               30s
service/istio-ingressgateway   NodePort    10.96.230.15    <none>        15021:31021/TCP,80:30080/TCP,443:30443/TCP   30s
service/istiod                 ClusterIP   10.96.45.12     <none>        15010/TCP,15012/TCP,443/TCP,15014/TCP        45s
```

Install the Kubernetes **Gateway API `v1.6.1`** CRDs as well (used in Modules 01 and 03):

```bash
kubectl get crd gateways.gateway.networking.k8s.io &> /dev/null || \
  kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml
```

---

## Step 3: Create Namespaces and Deploy the `OrderFlow` Platform

1. Create the `orderflow` (mesh-enabled) and `legacy-uninjected` (non-mesh) namespaces:

```bash
kubectl apply -f 00-environment-setup/manifests/namespace.yaml
```

2. Verify the `istio-injection=enabled` label on `orderflow`:

```bash
kubectl get ns -L istio-injection
```

3. Deploy the `OrderFlow` microservices:

```bash
kubectl apply -f 00-environment-setup/manifests/base-platform.yaml
```

> [!TIP]
> **Predict Before You Execute (`kubectl get pods -n orderflow`)**
> Open [`manifests/base-platform.yaml`](./manifests/base-platform.yaml) and count how many containers are defined inside each `Deployment`'s `spec.template.spec.containers` list (there is only `1`).
> - Before running `kubectl get pods -n orderflow`, what value do you expect in the `READY` column for pods in `orderflow` (`1/1` or `2/2`)?
> - What value do you expect in the `READY` column for `legacy-client` in `legacy-uninjected`? Why?

4. Wait for all pods to become `Ready` and check your prediction:

```bash
kubectl wait --for=condition=Ready pods --all -n orderflow --timeout=120s
kubectl get pods -n orderflow
kubectl get pods -n legacy-uninjected
```

**Expected Output (`orderflow`):**
```text
NAME                                    READY   STATUS    RESTARTS   AGE
client-toolbox-xxxx                     2/2     Running   0          45s
frontend-v1-xxxx                        2/2     Running   0          45s
inventory-service-v1-xxxx               2/2     Running   0          45s
order-service-v1-xxxx                   2/2     Running   0          45s
order-service-v1-yyyy                   2/2     Running   0          45s
order-service-v2-xxxx                   2/2     Running   0          45s
payment-service-v1-xxxx                 2/2     Running   0          45s
payment-service-v1-yyyy                 2/2     Running   0          45s
payment-service-v2-xxxx                 2/2     Running   0          45s
```

> [!IMPORTANT]
> Notice `READY 2/2` on every pod in `orderflow`, even though [`base-platform.yaml`](./manifests/base-platform.yaml) only defined **1 container** per Pod! In `legacy-uninjected`, `legacy-client` is `1/1`. That second container in `orderflow` is `istio-proxy` (Envoy `v1.40`), injected dynamically at pod creation time by `istiod`'s `MutatingAdmissionWebhook`.

---

## Step 4: Verify the End-to-End Microservices Call Graph

> [!TIP]
> **Predict Before You Execute (End-to-End Call Graph)**
> Before running the `curl` command below against `http://frontend.orderflow.svc.cluster.local`:
> 1. Which downstream services will appear inside `upstream_calls` of `frontend-v1`?
> 2. If you run the command 6 times in a row, roughly how often will `order-service-v1` respond versus `order-service-v2`, given that we haven't created any Istio `VirtualService` yet?

Execute an HTTP request from `client-toolbox` to `http://frontend.orderflow.svc.cluster.local` and format the JSON response with `jq`:

```bash
kubectl exec -n orderflow deploy/client-toolbox -c toolbox -- \
  curl -s http://frontend.orderflow.svc.cluster.local | jq .
```

**Expected Output:**
```json
{
  "name": "frontend-v1",
  "uri": "/",
  "type": "HTTP",
  "ip_addresses": [
    "10.244.1.5"
  ],
  "start_time": "2026-11-17T15:45:00.102000",
  "end_time": "2026-11-17T15:45:00.118000",
  "duration": "16ms",
  "body": "OrderFlow Web Storefront v1",
  "upstream_calls": {
    "http://order-service.orderflow.svc.cluster.local:8080": {
      "name": "order-service-v1",
      "uri": "http://order-service.orderflow.svc.cluster.local:8080",
      "type": "HTTP",
      "ip_addresses": [
        "10.244.2.6"
      ],
      "body": "Order Processing Engine v1 (Standard)",
      "upstream_calls": {
        "http://inventory-service.orderflow.svc.cluster.local:8080": {
          "name": "inventory-service-v1",
          "body": "Warehouse Inventory Ledger v1",
          "code": 200
        },
        "http://payment-service.orderflow.svc.cluster.local:8080": {
          "name": "payment-service-v2",
          "body": "Payment Gateway Adapter v2 (Multi-Currency Canary)",
          "code": 200
        }
      },
      "code": 200
    }
  },
  "code": 200
}
```

Verify that all 9 proxies in `orderflow` plus the 2 gateways in `istio-system` are synchronized with `istiod`:

```bash
istioctl proxy-status
```

All `CDS`, `LDS`, `EDS`, and `RDS` columns should report `SYNCED`.

---

## Step 5: Troubleshooting & Failure Injection Exercise (`INC-01` Simulation)

### Scenario: The Uninjected Audit Pod & Existing Pod Label Trap
Suppose a developer on Daniel Brooks's team creates a new namespace `orderflow-audit` and deploys an audit probe pod *before* labeling the namespace with `istio-injection=enabled`, or accidentally adds `sidecar.istio.io/inject: "false"` to the pod template.

Run the following command to simulate this broken deployment in `orderflow`:

```bash
kubectl run audit-probe -n orderflow \
  --image=curlimages/curl:8.10.1 \
  --labels="app=audit-probe,sidecar.istio.io/inject=false" \
  --command -- sleep 3600
```

Wait a few seconds and check the pod status:

```bash
kubectl get pod audit-probe -n orderflow
```

You will see `audit-probe` is `1/1 Running` instead of `2/2 Running`, and it does **not** appear in `istioctl proxy-status`!

### Your Challenge
Diagnose why `audit-probe` was not injected with `istio-proxy`, and determine why simply removing the label on a *running* Pod does not inject a sidecar in Sidecar Mode. Use the progressive hints below only if you get stuck.

<details>
<summary>Hint 1: Where to look</summary>

Check both the namespace labels (`kubectl get ns orderflow --show-labels`) and the pod's labels/annotations (`kubectl get pod audit-probe -n orderflow -o yaml`). Also remember *when* a Kubernetes `MutatingAdmissionWebhook` is invoked by `kube-apiserver`.
</details>

<details>
<summary>Hint 2: Diagnostic command</summary>

Run:
```bash
istioctl analyze -n orderflow
kubectl get pod audit-probe -n orderflow -o jsonpath='{.metadata.labels}'
```
Notice the label `sidecar.istio.io/inject: "false"`. In Kubernetes, `spec.containers` and `spec.initContainers` are immutable once a Pod is created—the `istio-sidecar-injector` `MutatingAdmissionWebhook` only fires on `CREATE` pod requests!
</details>

<details>
<summary>Full Explanation & Fix</summary>

**Root Cause:**
1. The pod had `sidecar.istio.io/inject=false` set in its metadata labels, which explicitly instructs `istiod`'s `MutatingAdmissionWebhook` to skip sidecar injection even in a namespace with `istio-injection=enabled`.
2. Because Kubernetes Pod container lists (`spec.containers`) cannot be mutated in-place after pod creation, patching the label on an already-running pod will **not** inject `istio-proxy`. The pod must be recreated (or rolled via `kubectl rollout restart deployment/<name>` for Deployments).

**Fix:**
Recreate the pod without `sidecar.istio.io/inject=false` (and then delete the test pod to keep `orderflow` clean):
```bash
kubectl delete pod audit-probe -n orderflow
kubectl run audit-probe -n orderflow --image=curlimages/curl:8.10.1 --command -- sleep 3600
kubectl wait --for=condition=Ready pod/audit-probe -n orderflow --timeout=60s
kubectl get pod audit-probe -n orderflow
```
Now `audit-probe` reports `2/2 Running`!
</details>

---

## Step 6: Cleanup / Reset Procedure

Before proceeding to Module 01, remove the temporary `audit-probe` pod while leaving the `istio-course` cluster, Istio `1.32.0`, and the `orderflow` baseline microservices running:

```bash
kubectl delete pod audit-probe -n orderflow --ignore-not-found
kubectl get pods -n orderflow
```

Confirm all 9 baseline `orderflow` pods remain `2/2 Running`.

---

## Production Considerations (Alex & Sarah's Checklist)

1. **Pin Exact Revision Tags (`istio.io/rev`) in Production**:
   While `istio-injection=enabled` is convenient in local labs, in production NovaPay uses revision tags (`istio.io/rev=1-32-0` or `istio.io/rev=prod-stable`). This allows running two control plane versions side-by-side during canary upgrades and rolling workloads namespace-by-namespace.
2. **Never Leave Un-named Service Ports in Kubernetes Manifests**:
   Run `istioctl analyze -A` in CI/CD pipelines to fail any pull request that introduces a Kubernetes `Service` port without an explicit `name: <protocol>-<suffix>` (`http-api`, `grpc-rpc`, `tcp-db`) or `appProtocol` field.
3. **Admission Webhook High Availability**:
   In production, `istiod` must run with at least `3` replicas across availability zones with a `PodDisruptionBudget` (`minAvailable: 2`). If all `istiod` pods are unavailable when a Deployment scales up, `istio-sidecar-injector` webhook timeouts can block pod creation across mesh-enrolled namespaces.

---

## Next Step
You are ready for **[Module 01: Istio Architecture, Envoy Internals & Dataplane Modes](../01-architecture-and-internals/README.md)**!
