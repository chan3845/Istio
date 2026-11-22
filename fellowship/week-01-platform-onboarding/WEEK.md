[Fellowship Portal](../../README.md) · [Handbook](../../FELLOWSHIP_HANDBOOK.md) · [Progression Dashboard](../../PROGRESSION_DASHBOARD.md) · **Week 01 of 10** · [Next Week ->](../week-02-dataplane-internals-and-ambient/WEEK.md)

# Week 01 — Platform Onboarding & Control Plane Provisioning

> **Phase 1: Foundations & Data Plane Internals** | **Cohort 01**
> **Authoritative Baseline**: Istio `1.32.0` | Envoy `v1.40` | Kubernetes `1.36` / `1.37` | Gateway API `v1.6.1`
> **Core Module Mapping**: [Module 00 — Environment Setup (`README.md`)](../../00-environment-setup/README.md) & [Guided Lab (`LAB.md`)](../../00-environment-setup/LAB.md)

> [!NOTE]
> ### Where You Are & What You Need Before Starting
> - **Current Phase**: Phase 1 — Foundations & Data Plane Internals (Week 01 of 10)
> - **Prerequisites**: Docker (`27.x+`), `kind` (`v0.27+`), `kubectl` (`1.36+`), `istioctl` (`1.32.0`), `helm` (`3.17+`), `jq`, and `openssl` installed locally
> - **Estimated Time**: ~6–8 hours (Monday Briefing through Sunday Assessment)
> - **Tangible Weekly Deliverable**: Running 4-node multi-zone `istio-course` cluster with Istio `1.32.0`, Gateway API `v1.6.1`, enrolled `orderflow` baseline workloads (`2/2 READY`), and onboarded `currency-service-v1` (`NP-101`)

---

## Week Metadata & Learning Objectives

| Attribute | Specification |
| :--- | :--- |
| **Fellowship Role** | Platform Engineer — Service Mesh & Cloud-Native Networking Team |
| **Business Context** | NovaPay is preparing for our upcoming PCI-DSS Level 1 audit and Black Friday peak checkout volume. We must establish a deterministic, auditable Istio `1.32.0` foundation before migrating production payment traffic. |
| **Primary Namespace** | `orderflow` (Core checkout subsystem; expands to multi-namespace `novapay` + `novapay-pci` in Week 10) |
| **Engineering Ticket** | `NP-101`: Provision Multi-Zone Cluster, Audit CNI & Istio `1.32.0` Profile Baseline, and Enroll `orderflow` |
| **Incident Simulation** | `INC-01`: Uninjected Checkout Pods & Protocol Sniffing Latency Spikes |

### Learning Objectives
By the end of Week 01, you will be able to:
1. Provision a multi-node, multi-zone Kubernetes `1.36+` cluster alongside Kubernetes Gateway API `v1.6.1` Standard CRDs.
2. Evaluate Istio `1.32.0` installation mechanisms (`istioctl` profiles vs. GitOps Helm charts) and articulate why the removed in-cluster `IstioOperator` controller and the `demo` profile are strictly prohibited in NovaPay production environments.
3. Audit CNI (`Cilium` / `kindnet`) socket-level load balancing interactions with Envoy's `iptables` interception (`REDIRECT` vs. `TPROXY`).
4. Enroll workloads into the mesh via namespace mutating webhook labels (`istio-injection=enabled`), verify Envoy `1.40` sidecar injection, and validate SPIFFE X.509 workload identities (`spiffe://cluster.local/ns/orderflow/sa/<service-account>`).

### Required Competencies
- Proficiency with `kubectl`, Kubernetes admission webhooks, `ServiceAccount` RBAC, and container port specifications.
- Ability to inspect Envoy bootstrap state and control plane synchronization via `istioctl version`, `istioctl proxy-status`, and `istioctl analyze`.

---

## Monday — Mentor Briefing & Ticket Assignment

### Welcome from Alex Morgan (Senior Platform Engineer)
> *"Welcome to NovaPay! I'm Alex Morgan, and I'll be your primary mentor during this fellowship. At NovaPay, we process thousands of payment authorizations per second. When a service mesh works, nobody notices; when it's misconfigured, every single checkout transaction fails with a cryptic `503`.*
>
> *Before we touch a single `VirtualService` or mTLS policy, we have to get our foundation right. Here is rule number one on my team: **we do not copy-paste tutorial YAML into production, and we never treat Envoy as a black box.** Every time you apply a configuration this week, I will ask you what `istiod` generated, how the mutating webhook altered the `Pod` spec, and what happens to a TCP SYN packet when it hits the node. Read the Monday thread from `#platform-mesh-arch` below, review ticket `NP-101`, and get your local multi-zone cluster stood up."*

### Peer Engineering Discussion (`#platform-mesh-arch`)

> **Daniel Brooks (Staff Backend Engineer)** `09:14 AM`
> Morning team. For the `orderflow` staging environment spin-up today, why aren't we just running `istioctl install --set profile=demo` or dropping an `IstioOperator` CRD into the cluster so ArgoCD can reconcile it? That's what I used at my last company back on Istio 1.18.

> **Alex Morgan (Senior Platform Engineer)** `09:17 AM`
> Two big reasons, Daniel. First, `IstioOperator` is legacy—the in-cluster `IstioOperator` controller was deprecated in 1.23 and **permanently removed** in 1.24. At NovaPay, we do not author `kind: IstioOperator` manifests at all; we install and manage Istio `1.32.0` using the **official Istio Helm charts** (`istio/base`, `istio/istiod`, `istio/gateway`) with clean, modular `values.yaml` files in both our local lab clusters and our production ArgoCD GitOps pipelines.
>
> Second, `profile=demo` is a ticking time bomb for any realistic workload. It sets `meshConfig.accessLogFile=/dev/stdout` unthrottled, sets trace sampling to `100%` (`PILOT_TRACE_SAMPLING=100`), and drops Envoy CPU/memory requests to miniature values. Under NovaPay load, `100%` trace sampling alone will saturate `istio-proxy` CPU and blow our checkout P99.

> **Sarah Chen (SRE Lead)** `09:20 AM`
> +100 to banning `profile=demo`. At 100% trace sampling and verbose stdout logging, our node disk I/O spiked by 40% during last quarter's load test. In `NP-101`, make sure we document the exact delta between `default`, `minimal`, and `ambient` profiles in `1.32.0`. We need deliberate telemetry sampling (`1%` in prod, `100%` only in isolated debug sandboxes) and predictable resource footprints.

> **Maya Patel (Principal Security Engineer)** `09:23 AM`
> Also, as we bring up the `orderflow` baseline pods (`frontend`, `order-service`, `payment-service`, `inventory-service`), I do NOT want them all sharing the `default` Kubernetes `ServiceAccount`. Under PCI-DSS Requirement 7 & 8, every microservice must have a distinct cryptographic identity. In Istio, a pod's X.509 SAN is derived directly from its `ServiceAccount` (`spiffe://cluster.local/ns/orderflow/sa/<sa-name>`). If two services share `default`, I can't write an L7 `AuthorizationPolicy` in Week 5 to distinguish them.

> **Daniel Brooks (Staff Backend Engineer)** `09:26 AM`
> Fair points. Just make sure whatever CNI settings you enforce don't break local development or silently bypass the sidecar. Look forward to seeing `NP-101` green.

---

### Engineering Ticket: `NP-101`

| Field | Details |
| :--- | :--- |
| **Ticket ID** | `NP-101` |
| **Title** | Provision Multi-Zone K8s Cluster, Install Istio `1.32.0` + Gateway API `v1.6.1`, and Onboard `orderflow` |
| **Reporter** | Alex Morgan (Senior Platform Engineer) |
| **Assignee** | Platform Engineering Fellow |
| **Priority** | P0 — Blocker for Phase 1 |

#### Business Context
NovaPay requires a local multi-zone simulation cluster (`1 control-plane`, `3 worker nodes` across `us-east-1a`, `us-east-1b`, `us-east-1c`) running Istio `1.32.0` and Kubernetes Gateway API `v1.6.1`. This environment will serve as our staging proving ground for the `orderflow` payment processing pipeline prior to production rollout.

#### Technical Requirements
1. **Cluster & Gateway API Setup**: Provision the 4-node `kind` cluster (`istio-course`) with topology zone labels and install Kubernetes Gateway API `v1.6.1` Standard CRDs (`GatewayClass`, `Gateway`, `HTTPRoute`, `GRPCRoute`, `ReferenceGrant`).
2. **Control Plane Installation**: Install Istio `1.32.0` with Envoy access logging enabled in `JSON` format, outbound traffic policy set to `ALLOW_ANY` (to be locked down in Week 4), and explicit ingress/egress gateways.
3. **Workload Enrollment**: Deploy the `orderflow` reference microservices (`frontend-v1` with `frontend-sa`, `order-service-v1`/`v2` with `order-sa`, `payment-service-v1`/`v2` with `payment-sa`, `inventory-service-v1` with `inventory-sa`, and `client-toolbox` with `toolbox-sa`, plus `legacy-client` in `legacy-uninjected` with `legacy-sa`) and verify automatic sidecar injection (`2/2 READY` in `orderflow`, `1/1 READY` in `legacy-uninjected`).
4. **Observability Addons**: Deploy Prometheus, Grafana, Jaeger, and Kiali into `istio-system` for golden-signal verification.

#### Constraints
- Do **not** deploy an in-cluster `IstioOperator` custom resource (removed in modern Istio).
- Every `Service` port in `orderflow` must strictly follow Istio explicit protocol naming (`http-*` or `grpc-*`) or `appProtocol` specifications.
- All workloads must run with dedicated `ServiceAccount` resources—zero workloads in `orderflow` may use the `default` `ServiceAccount`.

#### Acceptance Criteria & Deliverables
- [ ] All 4 Kubernetes nodes in `istio-course` report `Ready` with distinct `topology.kubernetes.io/zone` labels (`us-east-1a`, `us-east-1b`, `us-east-1c`).
- [ ] `istioctl version` reports Client `1.32.0`, Control Plane `1.32.0`, and Data Plane `1.32.0` across all proxies.
- [ ] `istioctl proxy-status` shows `SYNCED (100%)` for CDS, LDS, EDS, and RDS across all `orderflow` pods and gateways.
- [ ] End-to-end transaction probe from `client-toolbox` to `http://frontend.orderflow.svc.cluster.local:80/` returns `HTTP 200 OK` with verified JSON access logs in Envoy.

---

## Tuesday — Technical Lectures & Architecture Deep-Dive

### Assigned Core Reading & Modular Lessons
Read the complete architectural reference and manifest breakdowns in Module 00:
- **Core Module Reference**: [**Module 00 — Environment Setup & Lab Topology (`README.md`)**](../../00-environment-setup/README.md)
- **Reference Cluster & Baseline Manifests**:
  - [Multi-Zone Kind Cluster Topology (`kind-cluster.yaml`)](../../00-environment-setup/manifests/kind-cluster.yaml)
  - [Lab Control Plane Helm Values (`helm-values-istiod.yaml`)](../../00-environment-setup/manifests/helm-values-istiod.yaml)
  - [Ingress & Egress Gateway Helm Values (`helm-values-ingressgateway.yaml` & `helm-values-egressgateway.yaml`)](../../00-environment-setup/manifests/helm-values-ingressgateway.yaml)
  - [Production HA GitOps Helm Values (`helm-values-prod.yaml`)](../../00-environment-setup/manifests/helm-values-prod.yaml)
  - [OrderFlow Reference Workloads (`base-platform.yaml`)](../../00-environment-setup/manifests/base-platform.yaml)

### Alex's Guided Study Notes: What to Pay Attention to Under the Hood
While reading Module 00, focus closely on these three production engineering realities:

1. **Why Mutating Admission Webhooks Depend on Namespace Labels**:
   When you run `kubectl apply -f deployment.yaml`, the `kube-apiserver` intercepts the `Pod` creation request and invokes the `istio-sidecar-injector` `MutatingWebhookConfiguration`. That webhook evaluates an `objectSelector` and `namespaceSelector`. If the namespace lacks `istio-injection: enabled` (or a matching `istio.io/rev` label during canary control-plane upgrades), the webhook never fires, and your pod starts `1/1` in plaintext without a sidecar.
2. **Cilium CNI Socket-Level Load Balancing vs. Envoy `iptables`**:
   In clusters using Cilium with `socketLB.enabled=true` (eBPF `connect()` syscall hooks), Cilium rewrites the destination ClusterIP to the backend Pod IP *at the socket layer* before packets ever traverse `netfilter`/`iptables`. For sidecar mode, this bypasses `istio-proxy` on the client side unless `socketLB.hostNamespaceOnly=true` is configured in Cilium! Always audit your CNI's eBPF datapath before installing Istio.
3. **Port Naming & Protocol Sniffing Cost**:
   If a Kubernetes `Service` port is named `port: 8080, name: web` without `appProtocol: http`, `istiod` configures the Envoy Listener with a protocol sniffing filter (`envoy.filters.listener.http_inspector`). If a client opens a connection and waits for the server to speak first, or if traffic is high-throughput RPC, protocol sniffing introduces up to a `5s` protocol detection timeout or drops L7 telemetry entirely (falling back to `PassthroughCluster` / raw TCP).

### Architectural Trade-off Matrix: Istio `1.32.0` Installation & Configuration Profiles

| Profile / Method | Components Installed | Default Telemetry & Sampling | Resource Footprint | NovaPay Production Verdict |
| :--- | :--- | :--- | :--- | :--- |
| **`default` Profile** (`istioctl` / Helm) | `istiod`, `istio-ingressgateway` | No stdout access log by default; `1%` trace sampling | Production-ready defaults (`100m` CPU / `128Mi` RAM per proxy) | **Approved** (via Helm in GitOps; via `istioctl` with explicit overrides in lab) |
| **`demo` Profile** | `istiod`, `istio-ingressgateway`, `istio-egressgateway` | Stdout access logging on; **`100%` trace sampling** | Artificially low (`10m` CPU / `40Mi` RAM requests) | **Banned in Prod/Staging** — Causes severe Envoy CPU exhaustion and disk I/O saturation under load |
| **`minimal` Profile** | `istiod` only (zero gateways) | Standard defaults | Minimal control plane only | **Approved** when using pure Kubernetes Gateway API where gateways are deployed dynamically per `Gateway` CR |
| **`ambient` Profile** | `istiod`, `istio-cni`, `ztunnel` DaemonSet | L4 telemetry at `ztunnel`; optional L7 at Waypoint | Shared per-node L4 proxy | **Evaluated in Week 02** for high-density batch workloads |
| **In-Cluster `IstioOperator` Controller** | *Removed in modern Istio* | N/A | High privileged cluster-admin footprint | **Removed / Prohibited** — Use Helm or client-side `istioctl` |

---

## Wednesday — Guided Labs & Internal Verification

### Step 1: Pre-Flight Environment & Version Audit
Before starting the guided lab, verify your workstation binaries match the Fellowship baseline:

```bash
kubectl version --client
istioctl version --remote=false
kind version
```

Expected baseline:
- `kubectl`: `v1.36.x` or `v1.37.x`
- `istioctl`: `1.32.0`
- `kind`: `v0.27.0+`

### Step 2: Execute the Core Module Guided Lab
Complete all steps in [**Module 00 — Hands-On Lab (`LAB.md`)**](../../00-environment-setup/LAB.md) to:
1. Create the 4-node multi-zone `istio-course` cluster.
2. Install Gateway API `v1.6.1` Standard CRDs.
3. Install Istio `1.32.0` (`istiod`, `istio-ingressgateway`, `istio-egressgateway`) and observability addons.
4. Deploy the `orderflow` baseline workloads (`frontend`, `order-service`, `payment-service`, `inventory-service`, `client-toolbox`) and `legacy-client` in `legacy-uninjected`, and verify East-West connectivity.

### Step 3: Alex's Internal Verification Checkpoints
Do not move to Thursday's independent assignment until every single checkpoint below passes on your cluster:

```bash
# Checkpoint 1: Verify Gateway API v1.6.1 CRDs are established
kubectl get crd gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io \
  -o custom-columns=NAME:.metadata.name,VERSION:.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version

# Checkpoint 2: Verify MutatingWebhookConfiguration is active and has a populated CA bundle
kubectl get mutatingwebhookconfiguration istio-sidecar-injector -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | wc -c

# Checkpoint 3: Verify Envoy v1.40 version and 100% xDS synchronization
istioctl proxy-status

# Checkpoint 4: Inspect the SPIFFE X.509 certificate injected into order-service-v1 in memory
ORDER_POD=$(kubectl get pod -n orderflow -l app=order-service,version=v1 -o jsonpath='{.items[0].metadata.name}')
istioctl proxy-config secret "$ORDER_POD.orderflow" -o json | jq -r '.dynamicActiveSecrets[] | select(.name=="default") | .secret.tlsCertificate.certificateChain.inlineBytes' | base64 -d | openssl x509 -noout -text | grep -A 1 "Subject Alternative Name"
```

You must see `URI:spiffe://cluster.local/ns/orderflow/sa/order-sa` in the X.509 Subject Alternative Name output.

---

## Thursday — Independent Engineering Assignment

### Scenario: Onboarding `currency-service-v1` for Multi-Currency Settlement
NovaPay is expanding into European and UK merchant settlements. Daniel Brooks's team has built a new microservice, `currency-service`, which exposes two endpoints:
- Port `8080`: REST HTTP endpoint for real-time FX conversion rates.
- Port `9090`: gRPC endpoint for high-throughput batch FX settlement streams.

Your task is to onboard `currency-service-v1` into the `orderflow` namespace following every NovaPay production standard.

### Technical Requirements & Constraints
1. Create a dedicated `ServiceAccount` named `currency-service-sa` in the `orderflow` namespace.
2. Create a Kubernetes `Service` named `currency-service` in `orderflow` exposing:
   - Port `8080` named `http-fx` with `appProtocol: http` targeting container port `8080`.
   - Port `9090` named `grpc-settlement` with `appProtocol: grpc` targeting container port `9090`.
3. Create a `Deployment` named `currency-service-v1` in `orderflow` with:
   - Labels: `app: currency-service`, `version: v1`.
   - Image: `mendhak/http-https-echo:35` (configured with `HTTP_PORT=8080` and `HTTPS_PORT=9090` as our lab stub).
   - Resource requests (`50m` CPU, `64Mi` memory) and limits (`200m` CPU, `128Mi` memory).
   - Explicit pod annotations setting `sidecar.istio.io/proxyCPU: "50m"` and `sidecar.istio.io/proxyMemory: "128Mi"`.
4. Verify that:
   - The pod starts `2/2 Running` with `istio-proxy` injected.
   - `istioctl analyze -n orderflow` reports **zero** validation warnings or errors.
   - `istioctl proxy-config listener` confirms Envoy generated an `http_connection_manager` filter for port `8080` (not raw TCP passthrough).
   - The workload's SPIFFE URI is `spiffe://cluster.local/ns/orderflow/sa/currency-service-sa`.

<details>
<summary>Need a Hint from Alex Morgan? (Click before revealing the full answer)</summary>

> **Alex's Coaching Hints**:
> 1. **Dual Protocol Port Specification**: In your `Service` YAML (`spec.ports[]`), always include **both** the Istio port name prefix (`name: http-fx`, `name: grpc-settlement`) **and** the Kubernetes `appProtocol` field (`appProtocol: http`, `appProtocol: grpc`). That ensures both `istioctl analyze` (`IST0118`) and Kubernetes-native tooling classify the L7 protocol without falling back to protocol sniffing.
> 2. **Proxy Resource Annotations**: Place `sidecar.istio.io/proxyCPU: "50m"` and `sidecar.istio.io/proxyMemory: "128Mi"` under `spec.template.metadata.annotations` (on the Pod template), **not** on `metadata.annotations` of the `Deployment` object!
> 3. **SPIFFE Identity Binding**: Remember to set `spec.template.spec.serviceAccountName: currency-service-sa` so `pilot-agent` requests an X.509 certificate for `currency-service-sa` instead of `default`.

</details>

<details>
<summary>Click to Reveal Reference Solution & Alex's Code Review</summary>

### Reference Solution Manifest (`currency-service.yaml`)

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: currency-service-sa
  namespace: orderflow
  labels:
    app: currency-service
---
apiVersion: v1
kind: Service
metadata:
  name: currency-service
  namespace: orderflow
  labels:
    app: currency-service
    service: currency-service
spec:
  ports:
    - port: 8080
      targetPort: 8080
      name: http-fx
      appProtocol: http
    - port: 9090
      targetPort: 9090
      name: grpc-settlement
      appProtocol: grpc
  selector:
    app: currency-service
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: currency-service-v1
  namespace: orderflow
  labels:
    app: currency-service
    version: v1
spec:
  replicas: 1
  selector:
    matchLabels:
      app: currency-service
      version: v1
  template:
    metadata:
      labels:
        app: currency-service
        version: v1
      annotations:
        sidecar.istio.io/proxyCPU: "50m"
        sidecar.istio.io/proxyMemory: "128Mi"
    spec:
      serviceAccountName: currency-service-sa
      containers:
        - name: currency-service
          image: mendhak/http-https-echo:35
          ports:
            - containerPort: 8080
              name: http-fx
            - containerPort: 9090
              name: grpc-settlement
          env:
            - name: SERVICE_NAME
              value: "currency-service"
            - name: SERVICE_VERSION
              value: "v1"
            - name: HTTP_PORT
              value: "8080"
            - name: HTTPS_PORT
              value: "9090"
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
```

### Verification Commands

```bash
# 1. Apply the manifest and wait for rollout
kubectl apply -f currency-service.yaml
kubectl rollout status deployment/currency-service-v1 -n orderflow

# 2. Run static analysis on the namespace
istioctl analyze -n orderflow

# 3. Verify Envoy listener protocol detection for port 8080
CURRENCY_POD=$(kubectl get pod -n orderflow -l app=currency-service,version=v1 -o jsonpath='{.items[0].metadata.name}')
istioctl proxy-config listener "$CURRENCY_POD.orderflow" --port 8080

# 4. Verify SPIFFE identity from client-toolbox
TOOLBOX_POD=$(kubectl get pod -n orderflow -l app=client-toolbox -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n orderflow "$TOOLBOX_POD" -c toolbox -- curl -s http://currency-service.orderflow.svc.cluster.local:8080/fx | jq -r '.headers["x-forwarded-client-cert"]'
```

### Alex's Code Review
> *"Clean work. Notice two details in your solution that separate senior platform engineers from beginners:*
> 1. *You defined **both** `name: http-fx` and `appProtocol: http` on the `Service`. While Kubernetes 1.20+ standardized `appProtocol`, many third-party observability tools and older Envoy filter generators still inspect the `name` prefix (`http-*`, `grpc-*`). Providing both guarantees zero ambiguity.*
> 2. *Checking `x-forwarded-client-cert` (`XFCC`) in the echo output proved that mutual TLS happened transparently over the wire and that `currency-service` verified the caller's SPIFFE identity (`spiffe://cluster.local/ns/orderflow/sa/toolbox-sa`) without a single line of TLS code in the application."*

</details>

---

## Friday — Incident Simulation (`INC-01`)

### PagerDuty Alert: `INC-01` — Uninjected Recon Pods & Protocol Sniffing Timeouts

> **CRITICAL ALERT — `#inc-01-recon-onboarding`**
> **Incident Commander**: Sarah Chen (SRE Lead)
> **Symptom**: A product team just deployed a new `settlement-recon` service in a dedicated `orderflow-recon` namespace and also updated the `inventory-service` `Service` definition in `orderflow`. Two issues are firing simultaneously:
> 1. Every pod in `orderflow-recon` is starting `1/1 Running` with **no Envoy sidecar**, failing Maya's compliance scanner.
> 2. Calls from `order-service` to `inventory-service` in `orderflow` are experiencing erratic protocol detection delays, and `istioctl analyze` is throwing warnings on `inventory-service`.

### Step 1: Inject the Broken State
Run the following script to reproduce the exact state left behind by the product team's failed deployment:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: orderflow-recon
  labels:
    istio-injection: "true"
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: settlement-recon-sa
  namespace: orderflow-recon
---
apiVersion: v1
kind: Service
metadata:
  name: settlement-recon
  namespace: orderflow-recon
spec:
  ports:
    - port: 8080
      targetPort: 8080
      name: web-port
  selector:
    app: settlement-recon
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: settlement-recon-v1
  namespace: orderflow-recon
spec:
  replicas: 1
  selector:
    matchLabels:
      app: settlement-recon
      version: v1
  template:
    metadata:
      labels:
        app: settlement-recon
        version: v1
    spec:
      serviceAccountName: settlement-recon-sa
      containers:
        - name: settlement-recon
          image: mendhak/http-https-echo:35
          ports:
            - containerPort: 8080
          env:
            - name: HTTP_PORT
              value: "8080"
---
apiVersion: v1
kind: Service
metadata:
  name: inventory-service
  namespace: orderflow
  labels:
    app: inventory-service
    service: inventory-service
spec:
  ports:
    - port: 8080
      targetPort: 8080
      name: custom-inventory-port
  selector:
    app: inventory-service
EOF
```

### Step 2: Diagnostic Clues & Investigation Prompts
Use your diagnostic toolkit (`kubectl`, `istioctl analyze`, `istioctl check-inject`) to investigate before opening the RCA:
1. Run `istioctl analyze --all-namespaces`. Which exact analyzer codes (`IST01XX`) fire on `orderflow-recon` and `orderflow`?
2. Run `istioctl experimental check-inject -n orderflow-recon $(kubectl get pod -n orderflow-recon -l app=settlement-recon -o jsonpath='{.items[0].metadata.name}')`. Why did the `istio-sidecar-injector` webhook skip the pod?
3. Inspect the `inventory-service` outbound listener on `order-service-v1` using `istioctl proxy-config listener <order-pod>.orderflow --port 8080`. How did changing `name: http-api` to `name: custom-inventory-port` change the Envoy listener configuration?

<details>
<summary>Need a Hint from Alex Morgan? (Click before revealing the full answer)</summary>

> **Alex's Diagnostic Hints**:
> 1. Check the exact value of the `istio-injection` label on `Namespace/orderflow-recon` (`kubectl get ns orderflow-recon --show-labels`). Compare it against the `namespaceSelector` inside `kubectl get mutatingwebhookconfiguration istio-sidecar-injector -o yaml`. What value does the webhook actually match—`"true"` or `"enabled"`?
> 2. Remember that Kubernetes Mutating Admission Webhooks only run when a `Pod` is **created**. After fixing the namespace label, what must you do to `deployment/settlement-recon-v1` so the webhook fires?
> 3. Look at `Service/inventory-service` in `orderflow` and `Service/settlement-recon` in `orderflow-recon`. Neither `custom-inventory-port` nor `web-port` starts with a recognized Istio protocol prefix (`http-*`, `grpc-*`, `tcp-*`), and neither sets `appProtocol: http`.

</details>

<details>
<summary>Click to Reveal Root Cause Analysis (RCA), Remediation & Postmortem</summary>

### Root Cause Analysis (5-Whys)
1. **Why did `settlement-recon-v1` start with `1/1` containers (no `istio-proxy`)?**
   Because the `istio-sidecar-injector` mutating webhook did not match the `orderflow-recon` namespace.
2. **Why did the mutating webhook ignore the `orderflow-recon` namespace?**
   Because the namespace was labeled `istio-injection: "true"` instead of `istio-injection: enabled`. The webhook's `namespaceSelector` explicitly requires `istio-injection: enabled` (`IST0135` / `IST0116`).
3. **Why does labeling the namespace `istio-injection: enabled` not immediately fix the running pod?**
   Because Kubernetes mutating admission webhooks only execute during `CREATE` events for `Pod` objects. Existing pods must be recreated (`kubectl rollout restart`) after fixing the namespace label.
4. **Why did `inventory-service` lose explicit L7 HTTP routing and trigger `IST0118` warnings?**
   Because the engineer renamed the `Service` port from `http-api` to `custom-inventory-port` and omitted `appProtocol: http`.
5. **Why does `custom-inventory-port` degrade data plane behavior?**
   Without a recognized prefix (`http-*`, `grpc-*`, `tcp-*`) or `appProtocol`, `istiod` cannot statically build an L7 `http_connection_manager` listener and must fall back to dynamic protocol sniffing, risking 5-second protocol detection delays on server-first protocols and breaking explicit L7 policy predictability.

### Remediation Commands

```bash
# 1. Fix the namespace label on orderflow-recon
kubectl label namespace orderflow-recon istio-injection=enabled --overwrite

# 2. Fix the port naming on settlement-recon and inventory-service
kubectl patch service settlement-recon -n orderflow-recon --type='json' \
  -p='[{"op": "replace", "path": "/spec/ports/0/name", "value": "http-recon"}, {"op": "add", "path": "/spec/ports/0/appProtocol", "value": "http"}]'

kubectl patch service inventory-service -n orderflow --type='json' \
  -p='[{"op": "replace", "path": "/spec/ports/0/name", "value": "http-api"}, {"op": "add", "path": "/spec/ports/0/appProtocol", "value": "http"}]'

# 3. Trigger a rolling restart of settlement-recon-v1 so the MutatingWebhook injects istio-proxy
kubectl rollout restart deployment/settlement-recon-v1 -n orderflow-recon
kubectl rollout status deployment/settlement-recon-v1 -n orderflow-recon

# 4. Verify 2/2 READY and zero analyzer warnings
kubectl get pods -n orderflow-recon
istioctl analyze -n orderflow -n orderflow-recon

# 5. Clean up temporary incident namespace when finished
kubectl delete namespace orderflow-recon
kubectl delete -f currency-service.yaml --ignore-not-found
```

</details>

---

## Saturday — Architecture Review & Mentor Office Hours

### Architecture Defense Questions
Prepare concise, technically rigorous answers to these four questions from the NovaPay architecture review board:

1. **Alex Morgan (Platform)**: *"During an Istio control plane upgrade from `1.31` to `1.32.0`, why would we use `istio.io/rev=1-32-0` revision labels on namespaces instead of `istio-injection=enabled`? What happens to running pods in `orderflow` the moment we flip the revision label?"*
2. **Sarah Chen (SRE)**: *"Suppose `istiod` in `istio-system` crashes completely or scales to zero replicas during a Friday peak traffic spike. What happens to existing checkout requests flowing through `frontend` -> `order-service` -> `payment-service`? What breaks, and what continues working?"*
3. **Daniel Brooks (Backend)**: *"In our CI/CD pipeline, how can we fail a pull request BEFORE it gets merged if a developer forgets to name a `Service` port `http-*` or writes `istio-injection: true`?"*
4. **Maya Patel (Security)**: *"Where is the private key for `spiffe://cluster.local/ns/orderflow/sa/payment-sa` stored? If an attacker gains read access to etcd on the Kubernetes control plane, can they extract that workload's mTLS private key?"*

### Alex's Office Hours Q&A (Deep-Dive Edge Cases)

**Q1: Revision Labels vs. `istio-injection=enabled` & Pod Restart Mechanics**
> **Alex's Answer**: `istio-injection=enabled` points to the single default webhook revision. In production, doing an in-place upgrade of `istiod` carries blast-radius risk. By installing a canary `istiod` with `--set revision=1-32-0`, we can relabel one namespace at a time (`kubectl label ns orderflow istio-injection- istio.io/rev=1-32-0`). Changing the namespace label has **zero immediate effect** on running pods because admission webhooks only fire on `Pod` creation (`CREATE` admission phase). The pods only pick up the `1.32.0` proxy config and connect to the new `istiod-1-32-0` control plane when we trigger a rolling restart (`kubectl rollout restart deployment -n orderflow`).

**Q2: Control Plane Outage (`istiod` Down) vs. Data Plane Survival**
> **Alex's Answer**: Istio strictly decouples the control plane from the data plane packet path. `istiod` never sits in the path of application packets. If `istiod` goes completely down:
> - **What continues working**: Existing `istio-proxy` instances keep their last known good xDS configuration (Listeners, Routes, Clusters, Endpoints) and active TLS certificates in memory. Existing traffic between running pods continues flowing with zero interruption.
> - **What breaks**: (1) **No new pods can start** in injected namespaces if `istio-sidecar-injector` webhook fails closed (or if `pilot-agent` inside a new pod cannot complete its initial xDS and SDS CSR bootstrap); (2) **Endpoint updates stop**: if `payment-service` scales out or a pod dies and gets a new IP, `istiod` isn't there to push EDS updates, leading to `503 UF` calls to stale pod IPs; (3) **Certificate rotation halts**: when workload SVIDs approach expiration (default 24h TTL), `pilot-agent` cannot renew them via SDS/CA.

**Q3: Shift-Left CI Validation**
> **Alex's Answer**: You don't need a live cluster to run `istioctl analyze`! In CI, run `istioctl analyze --use-kube=false -f manifests/` against the rendered Kubernetes manifests before merge. It catches `IST0118` (port naming) and `IST0135` (`istio-injection: true` typo) statically in under a second.

**Q4: Workload Private Key Security (SDS & In-Memory Generation)**
> **Alex's Answer**: An attacker who dumps `etcd` **cannot** steal workload mTLS private keys! Unlike Kubernetes TLS Ingress `Secret` objects, Istio workload keys are never stored in Kubernetes `Secret` resources or `etcd`. Inside each pod, `pilot-agent` generates the private key **exclusively in process memory**, creates an X.509 Certificate Signing Request (CSR), and sends only the public CSR over gRPC to `istiod`. `istiod` returns the signed certificate chain, and `pilot-agent` pushes the key + cert to Envoy over a local Unix Domain Socket (`SDS`). The private key never leaves the pod's RAM and never touches disk.

---

## Sunday — Weekly Assessment & Reflection

### Competency Assessment
Test your mastery of Week 01 concepts before checking the answer key.

1. **Webhook & Admission Lifecycle**:
   A platform engineer applies `istio-injection=enabled` to the `orderflow` namespace, where 10 pods are already running. However, one specific pod (`legacy-batch-exporter`) in `orderflow` must **never** receive a sidecar even when restarted.
   - *(a)* Which exact **Pod template label** (not annotation—annotations were deprecated for injection control) disables sidecar injection for that single workload in Istio `1.32.0`?
   - *(b)* Why did Istio deprecate the `sidecar.istio.io/inject: "false"` annotation in favor of a label?

2. **CNI & eBPF Interaction**:
   You are deploying Istio `1.32.0` in Sidecar Mode onto an EKS cluster running Cilium CNI with eBPF kube-proxy replacement. Outbound `curl` requests from `order-service` to `http://payment-service:8080` completely ignore the `VirtualService` timeout and retry rules you configured, yet inbound requests to `payment-service` still show up in `payment-service`'s `istio-proxy` logs.
   - *(a)* Explain the kernel/socket mechanism causing the client-side `istio-proxy` to be bypassed.
   - *(b)* What specific Cilium Helm value fixes this for Sidecar Mode?

3. **xDS Synchronization Diagnostics**:
   When running `istioctl proxy-status`, you see `CDS: SYNCED`, `LDS: SYNCED`, `EDS: STALE (Never Acknowledged)` for `frontend-v1-xxx.orderflow`.
   - *(a)* What does `EDS` stand for, and what Kubernetes resource changes trigger an `EDS` push?
   - *(b)* What does `STALE` indicate in the gRPC ADS protocol between `istiod` and `istio-proxy`?

4. **Protocol Selection & Sniffing**:
   Why does a MySQL or Redis server (which is a **server-first** protocol where the server sends a greeting packet immediately upon TCP connection before the client sends any bytes) frequently time out or hang for 5 seconds when its Kubernetes `Service` port is named `port-3306` instead of `tcp-mysql`?

5. **Installation Architecture**:
   Why did the Istio project remove the in-cluster `IstioOperator` controller, and what are the two supported production upgrade workflows in Istio `1.32.0`?

<details>
<summary>Assessment Answer Key</summary>

1. **Webhook & Admission Lifecycle**:
   - *(a)* Set the **label** `sidecar.istio.io/inject: "false"` under `spec.template.metadata.labels` of the `Deployment`.
   - *(b)* Kubernetes `MutatingWebhookConfiguration` `objectSelector` can only filter on **labels**, not annotations! When injection was controlled via an annotation, the `kube-apiserver` had to invoke the `istiod` webhook on every single pod creation just so `istiod` could read the annotation, whereas a label allows `kube-apiserver` itself to skip calling the webhook if `sidecar.istio.io/inject: "false"` is set.

2. **CNI & eBPF Interaction**:
   - *(a)* Cilium's eBPF socket-level load balancing (`cgroup/connect4`) intercepts the `connect()` system call inside the application container's network namespace and translates the destination `Service` ClusterIP directly to the backend `Pod` IP before any packet is emitted. More critically, in certain socket-LB modes, fast-path socket redirection bypasses `netfilter`/`iptables` `OUTPUT` chains inside the pod network namespace, skipping the client-side `istio-proxy` `:15001` redirect.
   - *(b)* Set `socketLB.hostNamespaceOnly=true` in Cilium so socket-level load balancing only runs in the host network namespace and allows standard `iptables` interception inside pod network namespaces.

3. **xDS Synchronization Diagnostics**:
   - *(a)* `EDS` is the **Endpoint Discovery Service**. It translates Kubernetes `EndpointSlice` (and `Endpoints`) objects—i.e., ready Pod IPs, ports, and locality zones—into Envoy `ClusterLoadAssignment` endpoints.
   - *(b)* `STALE` means `istiod` has sent a newer xDS `DiscoveryResponse` (with a new `nonce` and `version_info`) over the Aggregated Discovery Service (ADS) stream, and either Envoy has not yet replied with a `DiscoveryRequest` ACK, or Envoy rejected the configuration with a NACK (negative acknowledgment).

4. **Protocol Selection & Sniffing**:
   - When a port is named `port-3306` (unrecognized prefix), Envoy uses protocol sniffing (`http_inspector` / `tls_inspector`) and waits for the **client** to send the first bytes so it can inspect whether the bytes start with `GET /`, `POST /`, `PRI * HTTP/2.0`, or a TLS ClientHello. In a server-first protocol like MySQL, the client waits for the MySQL server greeting, while Envoy waits for the client to send bytes—creating a classic deadlock until Envoy's `protocolDetectionTimeout` (`5s`) expires and falls back to raw TCP! Naming the port `tcp-mysql` disables protocol sniffing immediately.

5. **Installation Architecture**:
   - The in-cluster `IstioOperator` controller required permanent `cluster-admin` privileges in the cluster to create/delete arbitrary cluster-scoped RBAC, CRDs, and webhooks, which violated enterprise least-privilege security models and duplicated GitOps controllers (ArgoCD/Flux). The two supported production upgrade workflows in `1.32.0` are **Canary (Revision-based) Upgrades** (`istio.io/rev`) and **In-Place Upgrades** using either **Helm** (`istio/base`, `istio/istiod`) or client-side **`istioctl`**.

</details>

---

### Weekly Competency Sign-Off Checklist
Before moving to **Week 02 (Data Plane Internals, Envoy xDS & Ambient Mesh)**, verify you have completed:
- [ ] Built the 4-node multi-zone `istio-course` cluster with Gateway API `v1.6.1` CRDs.
- [ ] Installed Istio `1.32.0` and verified `SYNCED` state across all `orderflow` workloads.
- [ ] Completed Thursday's `currency-service-v1` onboarding challenge and verified SPIFFE identities via `istioctl proxy-config secret`.
- [ ] Resolved Friday's `INC-01` simulation and eliminated all `istioctl analyze` warnings.

### Retrospective Reflection
In your engineering notes, write down:
1. How you would explain the journey of a `Pod` creation request through the `istio-sidecar-injector` webhook to a backend developer in 60 seconds.
2. What command you will run first next week whenever a pod returns an unexpected `503` error.
