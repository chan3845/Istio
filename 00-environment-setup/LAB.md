# Lab 00: Provisioning the Lab Cluster, Installing Istio, and Deploying OrderFlow

## Learning Objectives
- Provision a multi-node, multi-zone Kubernetes cluster using `kind` (or verify an existing cluster).
- Install Istio using `istioctl` and a custom `IstioOperator` manifest.
- Understand how namespace labels (`istio-injection=enabled`) trigger automatic Envoy sidecar injection.
- Deploy the `OrderFlow` microservices platform and inspect its multi-hop JSON call graph.

---

## Prerequisites & Version Baseline (November 2026)

> **Authoritative Version Baseline**:
> - **Istio**: `1.32.0` (Envoy Proxy `v1.40`)
> - **Kubernetes**: `v1.36+` (Supported window for Istio 1.32: `v1.33` – `v1.37`)
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

## Step 2: Run Pre-Check and Install Istio Control Plane & Gateways

Before installing Istio, always verify cluster compatibility with `istioctl x precheck`:

```bash
istioctl x precheck
```

**Expected Output:**
```text
✔ No issues found when checking the cluster. Istio is safe to install or upgrade!
```

Now install Istio `1.32.0` using our customized `IstioOperator` CLI input specification (or use Helm with [`manifests/helm-values-prod.yaml`](./manifests/helm-values-prod.yaml) in production GitOps pipelines):

```bash
istioctl install -f 00-environment-setup/manifests/istio-operator-demo-vs-prod.yaml -y
```

Verify that `istiod`, `istio-ingressgateway`, and `istio-egressgateway` are running in `istio-system`:

```bash
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

## Step 3: Create Namespaces and Deploy the OrderFlow Platform

1. Create the `orderflow` (mesh-enabled) and `legacy-uninjected` (non-mesh) namespaces:

```bash
kubectl apply -f 00-environment-setup/manifests/namespace.yaml
```

2. Verify the `istio-injection=enabled` label on `orderflow`:

```bash
kubectl get ns -L istio-injection
```

3. Deploy the OrderFlow microservices:

```bash
kubectl apply -f 00-environment-setup/manifests/base-platform.yaml
```

4. Wait for all pods to become `Ready`:

```bash
kubectl wait --for=condition=Ready pods --all -n orderflow --timeout=120s
kubectl get pods -n orderflow
```

**Expected Output:**
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
> Notice `READY 2/2` on every pod in `orderflow`, even though [`base-platform.yaml`](./manifests/base-platform.yaml) only defined **1 container** per Pod! In `legacy-uninjected`, run `kubectl get pods -n legacy-uninjected` and notice `legacy-client` is `1/1`. That second container in `orderflow` is `istio-proxy` (Envoy), injected dynamically by `istiod`!

---

## Step 4: Verify the End-to-End Microservices Call Graph

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

All `CDS`, `LDS`, `EDS`, and `RDS` columns should report `SYNCED`. You are now ready for **Module 01: Istio Architecture & Data Plane Internals**!

