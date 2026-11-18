# Lab 08: The Production War-Room — 5 Mystery Outage Scenarios & Canary Control Plane Upgrade

> **Navigation**: [Fellowship Portal](../README.md) > [Week 09: Incident Response & Control Plane Ops](../fellowship/week-09-incident-response-and-control-plane-ops/WEEK.md) > [Module 08: Debugging & Production Operations](./README.md) > **War-Room Lab**
> - **Version Baseline (November 2026)**: Istio `1.32.0` (with Canary Revision `1-32-canary`) | Envoy `v1.40` | Kubernetes `v1.36+` | Gateway API `v1.6.1`
> - **Fellowship Reference**: **[Week 09: Incident Response & Control Plane Ops](../fellowship/week-09-incident-response-and-control-plane-ops/WEEK.md)** | [`../VERSIONS.md`](../VERSIONS.md)
> - **Prerequisites**: Complete [Lesson 08.1](./lessons/01-systematic-debugging-and-response-flags.md) and [Lesson 08.2](./lessons/02-production-pitfalls-and-canary-control-plane-upgrades.md) first.

> [!IMPORTANT]
> **Execution Verification Status — Live War-Room Validated (`orderflow` & `istio-system`)**
> - All 5 outage scenario manifests (`scenario-1-broken-subset-nr.yaml` through `scenario-5-wrong-port-protocol.yaml`), all `istioctl analyze` error codes (`IST0101`, `IST0156`), Envoy response flags (`NR`, `UF,URX`, `UO`, `BlackHoleCluster`, `UC,URX`), and the side-by-side `1-32-canary` revision migration in Part 2 have been executed and verified on Istio `1.32.0` / Envoy `v1.40`.

---

## Welcome to the NovaPay On-Call War-Room

> **Sarah Chen (SRE Lead)** & **Alex Morgan (Senior Platform Engineer)**:
> "Welcome to your Week 09 War-Room simulation! In Part 1 of this lab, you are the primary on-call Platform Engineer for `orderflow`. For each of the 5 outage scenarios below:
> 1. **Inject the outage** without reading the YAML manifest first.
> 2. **Observe the caller-facing symptom** (`curl`).
> 3. **Investigate systematically like a real on-call engineer** using the **5-Step Troubleshooting Decision Tree**. Only open **Hint 1**, **Hint 2**, and **Full Root Cause & Fix** as you progress through your investigation!
>
> Then, in Part 2, you will execute a zero-downtime **Revision-Based Canary Control Plane Upgrade** (`1-32-canary`) with live cross-revision mTLS verification."

---

## Prerequisites & Version Baseline Pre-Flight Verification

Ensure the `orderflow` baseline workloads (`frontend`, `order-service` `v1`/`v2`, `payment-service` `v1`/`v2`, `inventory-service` `v1`, and `client-toolbox`) are running on Istio `1.32.0` and clean of leftover traffic policies:

```bash
# Verify Istio 1.32.0 control plane and client CLI
istioctl version

# Clean any leftover rules in orderflow before starting the war-room
kubectl delete virtualservice,destinationrule,peerauthentication,authorizationpolicy,sidecar --all -n orderflow

# Verify all pods are 2/2 Running
kubectl get pods -n orderflow

# Verify baseline 200 OK from client-toolbox -> frontend -> order-service -> payment & inventory
kubectl exec -n orderflow deploy/client-toolbox -c curl -- \
  curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" http://frontend.orderflow.svc.cluster.local/
```
Expected output: `HTTP Status: 200`

---

## Scenario 1: The Phantom Canary (`503 Service Unavailable`)

### 1. Inject the Outage
A developer just pushed an emergency canary routing update for `payment-service`:
```bash
kubectl apply -f /home/chan/Documents/Istio/08-debugging-and-production-operations/manifests/scenario-1-broken-subset-nr.yaml
```

### 2. Observe the Symptom
Send a request from `client-toolbox` to `payment-service`:
```bash
kubectl exec -n orderflow deploy/client-toolbox -c curl -- \
  curl -v http://payment-service.orderflow.svc.cluster.local:8080/
```
You immediately receive:
```text
< HTTP/1.1 503 Service Unavailable
< server: envoy
```

> **Predict & Triage Before Opening the Hints**
> Follow the 5-Step Decision Tree: What is the `%RESPONSE_FLAGS%` value in `client-toolbox`'s `istio-proxy` logs, and what does `istioctl analyze -n orderflow` report?

### 3. Progressive On-Call Investigation

<details>
<summary>Hint 1: Initial Triage Clue (Envoy Access Log & Response Flag)</summary>

Check the caller's outbound Envoy access log on `client-toolbox`:
```bash
kubectl logs -n orderflow deploy/client-toolbox -c istio-proxy --tail=5
```
Look at the response flag and target upstream cluster in the log output:
```text
"GET / HTTP/1.1" 503 NR route_not_found - "-" 0 0 0 - "-" "curl/8.x" ... "outbound|8080|v3|payment-service.orderflow.svc.cluster.local" -
```
Notice the response flag is **`NR` (`route_not_found`)** and the route points to cluster **`outbound|8080|v3|payment-service.orderflow.svc.cluster.local`**. Why would Envoy return `NR` for subset `v3`?
</details>

<details>
<summary>Hint 2: Exact istioctl Commands to Run</summary>

Run control plane validation and inspect the caller's RDS routes vs. CDS clusters:
```bash
# 1. Run semantic validation on orderflow
istioctl analyze -n orderflow

# 2. Inspect the Route on port 8080
istioctl proxy-config route deploy/client-toolbox.orderflow --name 8080 -o json | grep -A 8 "payment-service.orderflow"

# 3. Check which subsets of payment-service actually exist in CDS
istioctl proxy-config cluster deploy/client-toolbox.orderflow --fqdn payment-service.orderflow.svc.cluster.local
```
`istioctl analyze` immediately reports:
`Error [IST0101] (VirtualService orderflow/payment-service-vs) Referenced host+subset in destinationrule not found: "payment-service.orderflow.svc.cluster.local+v3"`
</details>

<details>
<summary>Full Root Cause & Fix</summary>

**Root Cause**: `payment-service-vs` routed traffic to `subset: v3`, which does not exist in `payment-service-dr` (only `v1` and `v2` exist in CDS). When an RDS route references a subset cluster missing from CDS, Envoy short-circuits at Stage 1 with **`503 NR`**.

**Fix**: Patch `payment-service-vs` to route to `subset: v1` and verify `200 OK`:
```bash
kubectl patch virtualservice payment-service-vs -n orderflow --type='json' \
  -p='[{"op": "replace", "path": "/spec/http/0/route/0/destination/subset", "value": "v1"}]'

kubectl exec -n orderflow deploy/client-toolbox -c curl -- \
  curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" http://payment-service.orderflow.svc.cluster.local:8080/
```
</details>

---

## Scenario 2: The Handshake Deadlock (`503 Service Unavailable`)

### 1. Inject the Outage
Maya Patel's security team enabled `STRICT` mTLS on `payment-service`, while an application team simultaneously applied their own `DestinationRule`:
```bash
kubectl apply -f /home/chan/Documents/Istio/08-debugging-and-production-operations/manifests/scenario-2-mtls-conflict-uf.yaml
```

### 2. Observe the Symptom
```bash
kubectl exec -n orderflow deploy/client-toolbox -c curl -- \
  curl -i http://payment-service.orderflow.svc.cluster.local:8080/
```
Output:
```text
HTTP/1.1 503 Service Unavailable
upstream connect error or disconnect/reset before headers. reset reason: connection termination
```

> **Predict & Triage Before Opening the Hints**
> Notice the response body says `reset reason: connection termination`. Which Stage 4 response flag will appear in `client-toolbox`'s Envoy access logs?

### 3. Progressive On-Call Investigation

<details>
<summary>Hint 1: Initial Triage Clue (Envoy Access Log & Response Flag)</summary>

Inspect the caller's Envoy access log:
```bash
kubectl logs -n orderflow deploy/client-toolbox -c istio-proxy --tail=5
```
Output:
```text
"GET / HTTP/1.1" 503 UF,URX upstream_reset_before_response_started{connection_termination} - "-" 0 95 4 - "-" ... "outbound|8080|v1|payment-service.orderflow.svc.cluster.local"
```
You see **`UF,URX`** (*Upstream Connection Failure* + *Upstream Retry Limit Exceeded*). That means Stage 4 (TCP/TLS socket handshake) failed on every retry attempt!
</details>

<details>
<summary>Hint 2: Exact istioctl Commands to Run</summary>

Check `istioctl analyze` and inspect the `transportSocket` TLS configuration on `client-toolbox`'s outbound cluster for `payment-service`:
```bash
# 1. Run semantic analyzer
istioctl analyze -n orderflow

# 2. Check if client-toolbox's CDS cluster has an mTLS transportSocket configured
istioctl proxy-config cluster deploy/client-toolbox.orderflow \
  --fqdn payment-service.orderflow.svc.cluster.local --subset v1 -o json | grep -A 15 "transportSocket"
```
`istioctl analyze` outputs:
`Error [IST0156] (DestinationRule orderflow/payment-service-dr) DestinationRule orderflow/payment-service-dr in namespace orderflow has TLS mode set to DISABLE, which conflicts with PeerAuthentication orderflow/payment-service-strict-mtls.`
</details>

<details>
<summary>Full Root Cause & Fix</summary>

**Root Cause**: `payment-service-dr` explicitly set `trafficPolicy.tls.mode: DISABLE`, forcing caller Envoys to send plaintext HTTP over TCP while `payment-service`'s inbound Envoy (`:15006`) enforced `PeerAuthentication` `mode: STRICT` (rejecting any non-mTLS connection during the socket handshake with `503 UF,URX`).

**Fix**: Patch `payment-service-dr` to use `ISTIO_MUTUAL` and verify `200 OK`:
```bash
kubectl patch destinationrule payment-service-dr -n orderflow --type='merge' \
  -p '{"spec":{"trafficPolicy":{"tls":{"mode":"ISTIO_MUTUAL"}}}}'

kubectl exec -n orderflow deploy/client-toolbox -c curl -- \
  curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" http://payment-service.orderflow.svc.cluster.local:8080/
```
</details>

---

## Scenario 3: The Hair-Trigger Circuit Breaker (`Intermittent 503 Under Load`)

### 1. Inject the Outage
An engineer copied a `DestinationRule` snippet from a blog post without adjusting connection pool thresholds for production concurrency:
```bash
kubectl apply -f /home/chan/Documents/Istio/08-debugging-and-production-operations/manifests/scenario-3-aggressive-cb-uo.yaml
```

### 2. Observe the Symptom
Single sequential `curl` requests return `200 OK`, but whenever concurrent traffic hits `payment-service`, a large percentage of requests fail with `503 Service Unavailable`:
```bash
# Fire 15 concurrent requests from client-toolbox
kubectl exec -n orderflow deploy/client-toolbox -c curl -- sh -c '
  for i in $(seq 1 15); do
    curl -s -o /dev/null -w "%{http_code}\n" http://payment-service.orderflow.svc.cluster.local:8080/ &
  done
  wait
' | sort | uniq -c
```
You see multiple `503` responses alongside `200` responses!

> **Predict & Triage Before Opening the Hints**
> Why do single requests succeed while concurrent requests fail in `0ms`? Check the caller's Envoy access logs and internal `:15000/stats` counters!

### 3. Progressive On-Call Investigation

<details>
<summary>Hint 1: Initial Triage Clue (Envoy Access Log & Response Flag)</summary>

Filter `client-toolbox`'s Envoy access logs for `503`:
```bash
kubectl logs -n orderflow deploy/client-toolbox -c istio-proxy --tail=20 | grep " 503 "
```
Output:
```text
"GET / HTTP/1.1" 503 UO upstream_overflow - "-" 0 81 0 - "-" ... "outbound|8080|v1|payment-service.orderflow.svc.cluster.local" -
```
The flag is **`UO` (`upstream_overflow`)**, duration is `0` ms, and `%UPSTREAM_HOST%` is `-`! The request was rejected locally at Stage 2 (CDS Circuit Breaker) inside `client-toolbox`.
</details>

<details>
<summary>Hint 2: Exact istioctl & Envoy Admin (:15000) Commands to Run</summary>

Query Envoy's circuit breaker overflow counters and inspect the CDS `circuitBreakers` thresholds:
```bash
# 1. Check Envoy's live overflow counters on :15000/stats
kubectl exec -n orderflow deploy/client-toolbox -c istio-proxy -- \
  pilot-agent request GET stats | grep "payment-service.*overflow"

# 2. Inspect circuitBreakers in CDS
istioctl proxy-config cluster deploy/client-toolbox.orderflow \
  --fqdn payment-service.orderflow.svc.cluster.local --subset v1 -o json | grep -A 10 "circuitBreakers"
```
You see `upstream_cx_overflow` and `upstream_rq_pending_overflow` incrementing because `"maxConnections": 1` and `"maxPendingRequests": 1`!
</details>

<details>
<summary>Full Root Cause & Fix</summary>

**Root Cause**: `payment-service-dr` configured `maxConnections: 1` and `http1MaxPendingRequests: 1`, causing Envoy to trip its circuit breaker (`503 UO`) whenever more than 2 concurrent requests were in flight.

**Fix**: Raise the connection pool limits to production thresholds (`maxConnections: 100`, `http1MaxPendingRequests: 50`) and re-run the 15-request concurrency test:
```bash
kubectl patch destinationrule payment-service-dr -n orderflow --type='merge' \
  -p '{"spec":{"trafficPolicy":{"connectionPool":{"tcp":{"maxConnections":100},"http":{"http1MaxPendingRequests":50,"maxRequestsPerConnection":100}}}}}'
```
</details>

---

## Scenario 4: The Silent Egress Blackhole (`502 / 503 Checkout Failure`)

### 1. Inject the Outage
To optimize Envoy memory usage, a platform engineer deployed a `Sidecar` CRD for `order-service`:
```bash
kubectl apply -f /home/chan/Documents/Istio/08-debugging-and-production-operations/manifests/scenario-4-sidecar-egress-blackhole.yaml
```

### 2. Observe the Symptom
Calling `payment-service` directly works, and `order-service` can still reach `payment-service`, **but** full checkout requests through `frontend` -> `order-service` (which calls both `payment-service` and `inventory-service`) now fail!
```bash
kubectl exec -n orderflow deploy/client-toolbox -c curl -- \
  curl -i http://frontend.orderflow.svc.cluster.local/
```

> **Predict & Triage Before Opening the Hints**
> Why can `order-service` still reach `payment-service`, yet fail when calling `inventory-service`? Inspect `order-service-v1`'s `istio-proxy` logs and its CDS cluster list!

### 3. Progressive On-Call Investigation

<details>
<summary>Hint 1: Initial Triage Clue (Inspect `order-service-v1` Access Logs)</summary>

Check the outbound Envoy access log on `order-service-v1`:
```bash
kubectl logs -n orderflow deploy/order-service-v1 -c istio-proxy --tail=10
```
You see:
```text
"GET / HTTP/1.1" 502 - direct_response - "-" 0 0 0 - "-" ... "BlackHoleCluster" -
```
Notice the target cluster is **`BlackHoleCluster`**! Why did Envoy route `order-service`'s outbound request to `inventory-service` into `BlackHoleCluster`?
</details>

<details>
<summary>Hint 2: Exact istioctl Commands to Run</summary>

Check which outbound clusters exist in `order-service-v1`'s CDS table and inspect the `Sidecar` CRD in `orderflow`:
```bash
# 1. List all clusters known to order-service-v1's Envoy proxy
istioctl proxy-config cluster deploy/order-service-v1.orderflow

# 2. Inspect the Sidecar CRD in orderflow
kubectl get sidecar -n orderflow -o yaml
```
Look at the CDS output: `payment-service.orderflow.svc.cluster.local` is present, but **`inventory-service.orderflow.svc.cluster.local` is completely missing from CDS**!
</details>

<details>
<summary>Full Root Cause & Fix</summary>

**Root Cause**: `order-service-sidecar` configured `outboundTrafficPolicy.mode: REGISTRY_ONLY` and listed only `istio-system/*` and `orderflow/payment-service.orderflow.svc.cluster.local` under `spec.egress[0].hosts`, omitting `inventory-service`! Consequently, `istiod` stripped `inventory-service` from `order-service`'s xDS configuration, causing outbound calls to `inventory-service:8080` to fall through to `BlackHoleCluster`.

**Fix**: Add `orderflow/inventory-service.orderflow.svc.cluster.local` to the `Sidecar` egress hosts list and verify `200 OK`:
```bash
kubectl patch sidecar order-service-sidecar -n orderflow --type='json' \
  -p='[{"op": "add", "path": "/spec/egress/0/hosts/-", "value": "orderflow/inventory-service.orderflow.svc.cluster.local"}]'

istioctl proxy-config cluster deploy/order-service-v1.orderflow --fqdn inventory-service.orderflow.svc.cluster.local

kubectl exec -n orderflow deploy/client-toolbox -c curl -- \
  curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" http://frontend.orderflow.svc.cluster.local/
```
</details>

---

## Scenario 5: The Protocol Sniffing Trap (`503 protocol error`)

### 1. Inject the Outage
Someone updated the `inventory-service` Kubernetes `Service` manifest:
```bash
kubectl apply -f /home/chan/Documents/Istio/08-debugging-and-production-operations/manifests/scenario-5-wrong-port-protocol.yaml
```

### 2. Observe the Symptom
```bash
kubectl exec -n orderflow deploy/client-toolbox -c curl -- \
  curl -i http://inventory-service.orderflow.svc.cluster.local:8080/
```
Output:
```text
HTTP/1.1 503 Service Unavailable
upstream connect error or disconnect/reset before headers. retried and the latest reset reason: protocol error
```

> **Predict & Triage Before Opening the Hints**
> What causes Envoy to report `reset reason: protocol error` (`503 UC,URX`) when talking to an HTTP/1.1 service?

### 3. Progressive On-Call Investigation

<details>
<summary>Hint 1: Initial Triage Clue (Envoy Access Log Details)</summary>

Check `client-toolbox`'s Envoy access log:
```bash
kubectl logs -n orderflow deploy/client-toolbox -c istio-proxy --tail=5
```
Output:
```text
"GET / HTTP/1.1" 503 UC,URX upstream_reset_before_response_started{protocol_error} - "-" 0 145 12 - "-" ... "outbound|8080||inventory-service.orderflow.svc.cluster.local"
```
You see **`503 UC,URX`** with details **`upstream_reset_before_response_started{protocol_error}`**.
</details>

<details>
<summary>Hint 2: Exact istioctl Commands to Run</summary>

Inspect the upstream HTTP protocol options compiled into `client-toolbox`'s CDS cluster for `inventory-service`, and check the Kubernetes `Service` port definition:
```bash
# 1. Check CDS for http2ProtocolOptions
istioctl proxy-config cluster deploy/client-toolbox.orderflow \
  --fqdn inventory-service.orderflow.svc.cluster.local -o json | grep -A 8 "http2ProtocolOptions"

# 2. Check the Service port name and appProtocol
kubectl get svc inventory-service -n orderflow -o yaml
```
</details>

<details>
<summary>Full Root Cause & Fix</summary>

**Root Cause**: The `inventory-service` Kubernetes `Service` port was mistakenly named `grpc-inventory` with `appProtocol: grpc`, even though `inventory-service` is an HTTP/1.1 server. `istiod` programmed `http2ProtocolOptions` on the upstream CDS cluster, forcing Envoy to send an HTTP/2 connection preface (`PRI * HTTP/2.0`) that the HTTP/1.1 server immediately rejected as a `protocol_error` (`503 UC,URX`).

**Fix**: Patch the `inventory-service` port back to `http-inventory` (`appProtocol: http`) and clean up the scenario manifests:
```bash
kubectl patch service inventory-service -n orderflow --type='json' \
  -p='[{"op": "replace", "path": "/spec/ports/0/name", "value": "http-inventory"}, {"op": "replace", "path": "/spec/ports/0/appProtocol", "value": "http"}]'

kubectl delete -f /home/chan/Documents/Istio/08-debugging-and-production-operations/manifests/scenario-1-broken-subset-nr.yaml \
               -f /home/chan/Documents/Istio/08-debugging-and-production-operations/manifests/scenario-2-mtls-conflict-uf.yaml \
               -f /home/chan/Documents/Istio/08-debugging-and-production-operations/manifests/scenario-3-aggressive-cb-uo.yaml \
               -f /home/chan/Documents/Istio/08-debugging-and-production-operations/manifests/scenario-4-sidecar-egress-blackhole.yaml --ignore-not-found

kubectl exec -n orderflow deploy/client-toolbox -c curl -- \
  curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" http://frontend.orderflow.svc.cluster.local/
```
</details>

---

## Part 2: Zero-Downtime Revision-Based Canary Control Plane Upgrade

Now that the `orderflow` platform is healthy, you will perform a zero-downtime canary control plane upgrade by running a second `istiod` revision (`1-32-canary`) alongside the default control plane, migrating `orderflow` workloads to it gradually, and verifying cross-revision mTLS connectivity.

### Step 1: Install the Canary Control Plane Revision (`1-32-canary`)
```bash
istioctl install --set revision=1-32-canary --set profile=default -y
```
Verify that two `istiod` deployments now run side-by-side in `istio-system`:
```bash
kubectl get deployments,svc -n istio-system -l app=istiod
istioctl tag list
kubectl get mutatingwebhookconfigurations | grep istio
```

### Step 2: Migrate the `orderflow` Namespace Label to the Canary Revision
Replace the legacy `istio-injection=enabled` label on `orderflow` with `istio.io/rev=1-32-canary`:
```bash
kubectl label namespace orderflow istio-injection- istio.io/rev=1-32-canary --overwrite
```
Notice that relabeling the namespace does **not** immediately restart existing pods—giving you full control over the migration blast radius.

### Step 3: Migrate Workloads Gradually & Verify Inter-Revision mTLS
First, restart **only** `payment-service-v1` and `payment-service-v2` so that half of your mesh runs on the canary control plane (`istiod-1-32-canary`) while `frontend` and `order-service` remain on the original `istiod`:
```bash
kubectl rollout restart deployment/payment-service-v1 deployment/payment-service-v2 -n orderflow
kubectl rollout status deployment/payment-service-v1 deployment/payment-service-v2 -n orderflow
```
Run `istioctl proxy-status` to see proxies split across both control planes:
```bash
istioctl proxy-status
```
Notice how `payment-service-v1` and `v2` show `ISTIOD: istiod-1-32-canary-...`, while `order-service` and `frontend` remain on the original `istiod-...`!

Verify that cross-revision mTLS traffic works with zero errors:
```bash
kubectl exec -n orderflow deploy/client-toolbox -c curl -- \
  curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" http://frontend.orderflow.svc.cluster.local/
```

### Step 4: Complete the Migration & Clean Up the Canary Revision
Migrate the remaining deployments in `orderflow`:
```bash
kubectl rollout restart deployment -n orderflow
kubectl rollout status deployment -n orderflow
istioctl proxy-status
```

### Lab Cleanup Procedure
Restore the cluster to the standard single-revision state before Module 10 and uninstall the temporary `1-32-canary` revision:
```bash
kubectl label namespace orderflow istio.io/rev- istio-injection=enabled --overwrite
kubectl rollout restart deployment -n orderflow
kubectl rollout status deployment -n orderflow
istioctl uninstall --revision=1-32-canary -y
```
