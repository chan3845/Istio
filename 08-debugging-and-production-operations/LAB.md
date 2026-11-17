# Lab 08: The Production War-Room — 5 Mystery Outage Scenarios & Canary Control Plane Upgrade

In this hands-on lab, you are the on-call Principal Mesh Engineer for the **OrderFlow** platform. You will inject 5 realistic production outages into the `orderflow` namespace, diagnose each one systematically using `istioctl analyze`, Envoy access logs (`%RESPONSE_FLAGS%`), and `istioctl proxy-config`, and restore the platform to full health. Finally, in Part 2, you will execute a zero-downtime **Revision-Based Canary Control Plane Upgrade**.

---

## Prerequisites & Baseline Check

Ensure the `orderflow` baseline workloads from Module 02 (`frontend`, `order-service` `v1`/`v2`, `payment-service` `v1`/`v2`, `inventory-service` `v1`, and `client-toolbox`) are running and clean of leftover traffic policies:

```bash
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

## Scenario 1: The Phantom Canary (`503 NR`)

### 1. Inject the Outage
A developer just pushed a canary routing update for `payment-service`:
```bash
kubectl apply -f manifests/scenario-1-broken-subset-nr.yaml
```

### 2. Observe the Symptom
Send a request from `client-toolbox` to `payment-service` (or through `order-service`):
```bash
kubectl exec -n orderflow deploy/client-toolbox -c curl -- \
  curl -v http://payment-service.orderflow.svc.cluster.local:8080/
```
You immediately receive:
```text
< HTTP/1.1 503 Service Unavailable
< server: envoy
```

### 3. Step-by-Step Diagnostic Investigation

**Step A: Check the client Envoy Access Logs for the Response Flag**
```bash
kubectl logs -n orderflow deploy/client-toolbox -c istio-proxy --tail=5
```
Look at the log entry:
```text
"GET / HTTP/1.1" 503 NR route_not_found - "-" 0 0 0 - "-" "curl/8.x" ... "outbound|8080|v3|payment-service.orderflow.svc.cluster.local" -
```
Notice two critical clues:
1. The response flag is **`NR`** (`route_not_found`).
2. The target cluster is `outbound|8080|v3|payment-service.orderflow.svc.cluster.local`.

**Step B: Run `istioctl analyze`**
```bash
istioctl analyze -n orderflow
```
Output:
```text
Error [IST0101] (VirtualService orderflow/payment-service-vs) Referenced host+subset in destinationrule not found: "payment-service.orderflow.svc.cluster.local+v3"
```

**Step C: Verify in Envoy's Route & Cluster tables (`istioctl pc`)**
```bash
# 1. Inspect the Route on port 8080
istioctl proxy-config route deploy/client-toolbox.orderflow --name 8080 -o json | grep -A 8 "payment-service.orderflow"

# 2. Check if cluster 'v3' exists in CDS
istioctl proxy-config cluster deploy/client-toolbox.orderflow --fqdn payment-service.orderflow.svc.cluster.local
```
You will see `outbound|8080|v1|...` and `outbound|8080|v2|...` in CDS, but **`v3` does not exist**! When an RDS route points to a cluster missing from CDS, Envoy returns `503 NR`.

### 4. Root Cause & Fix
`payment-service-vs` routed traffic to `subset: v3`, which was never defined in `payment-service-dr`. Update the `VirtualService` to route to `subset: v1` (or split `80/20` between `v1` and `v2`):

```bash
kubectl patch virtualservice payment-service-vs -n orderflow --type='json' \
  -p='[{"op": "replace", "path": "/spec/http/0/route/0/destination/subset", "value": "v1"}]'

# Verify 200 OK
kubectl exec -n orderflow deploy/client-toolbox -c curl -- \
  curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" http://payment-service.orderflow.svc.cluster.local:8080/
```

---

## Scenario 2: The Handshake Deadlock (`503 UF`)

### 1. Inject the Outage
The security team enabled `STRICT` mTLS on `payment-service`, while an application team simultaneously applied their own `DestinationRule`:
```bash
kubectl apply -f manifests/scenario-2-mtls-conflict-uf.yaml
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

### 3. Step-by-Step Diagnostic Investigation

**Step A: Inspect Client Envoy Access Logs**
```bash
kubectl logs -n orderflow deploy/client-toolbox -c istio-proxy --tail=5
```
Output:
```text
"GET / HTTP/1.1" 503 UF,URX upstream_reset_before_response_started{connection_termination} - "-" 0 95 4 - "-" ... "outbound|8080|v1|payment-service.orderflow.svc.cluster.local"
```
Here we see **`UF,URX`**:
- **`UF`** = Upstream Connection Failure (TCP/TLS handshake failed before HTTP headers could be exchanged).
- **`URX`** = Upstream Retry Limit Exceeded (Envoy retried the connection and failed every time).

**Step B: Run `istioctl analyze`**
```bash
istioctl analyze -n orderflow
```
Output:
```text
Error [IST0156] (DestinationRule orderflow/payment-service-dr) DestinationRule orderflow/payment-service-dr in namespace orderflow has TLS mode set to DISABLE, which conflicts with PeerAuthentication orderflow/payment-service-strict-mtls.
```

**Step C: Inspect the Cluster TLS Context in Envoy**
```bash
istioctl proxy-config cluster deploy/client-toolbox.orderflow \
  --fqdn payment-service.orderflow.svc.cluster.local --subset v1 -o json | grep -A 15 "transportSocket"
```
Notice there is **no `envoy.transport_sockets.tls`** configured on the client cluster—Envoy is sending raw plaintext HTTP over TCP to `payment-service`'s inbound `:15006` listener, which only accepts mTLS (`TLS ClientHello`)!

### 4. Root Cause & Fix
The `DestinationRule` set `trafficPolicy.tls.mode: DISABLE`, overriding Istio's auto-mTLS detection while `PeerAuthentication` required `STRICT` mTLS. Fix the `DestinationRule` to use `ISTIO_MUTUAL`:

```bash
kubectl patch destinationrule payment-service-dr -n orderflow --type='merge' \
  -p '{"spec":{"trafficPolicy":{"tls":{"mode":"ISTIO_MUTUAL"}}}}'

# Verify 200 OK
kubectl exec -n orderflow deploy/client-toolbox -c curl -- \
  curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" http://payment-service.orderflow.svc.cluster.local:8080/
```

---

## Scenario 3: The Hair-Trigger Circuit Breaker (`503 UO`)

### 1. Inject the Outage
An engineer copied a `DestinationRule` snippet from a tutorial without adjusting the connection pool limits for production concurrency:
```bash
kubectl apply -f manifests/scenario-3-aggressive-cb-uo.yaml
```

### 2. Observe the Symptom
Single sequential `curl` requests succeed (`200 OK`), but whenever concurrent traffic hits `payment-service`, a large percentage of requests fail with `503 Service Unavailable`:
```bash
# Fire 15 concurrent requests from client-toolbox
kubectl exec -n orderflow deploy/client-toolbox -c curl -- sh -c '
  for i in $(seq 1 15); do
    curl -s -o /dev/null -w "%{http_code}\n" http://payment-service.orderflow.svc.cluster.local:8080/ &
  done
  wait
' | sort | uniq -c
```
You will see several `503` responses alongside `200` responses!

### 3. Step-by-Step Diagnostic Investigation

**Step A: Check the Client Envoy Access Logs**
```bash
kubectl logs -n orderflow deploy/client-toolbox -c istio-proxy --tail=20 | grep " 503 "
```
Output:
```text
"GET / HTTP/1.1" 503 UO upstream_overflow - "-" 0 81 0 - "-" ... "outbound|8080|v1|payment-service.orderflow.svc.cluster.local" -
```
Notice two telltale indicators of **`UO` (`upstream_overflow`)**:
1. Duration is `0` ms.
2. Upstream host (`%UPSTREAM_HOST%`) at the end of the line is `-` (empty), proving the request was **short-circuited locally inside the client's Envoy proxy** and never even attempted over the network!

**Step B: Check the Envoy Circuit Breaker Overflow Counter (`:15000/stats`)**
```bash
kubectl exec -n orderflow deploy/client-toolbox -c istio-proxy -- \
  pilot-agent request GET stats | grep "payment-service.*overflow"
```
Output:
```text
cluster.outbound|8080|v1|payment-service.orderflow.svc.cluster.local.upstream_cx_overflow: 12
cluster.outbound|8080|v1|payment-service.orderflow.svc.cluster.local.upstream_rq_pending_overflow: 9
```

**Step C: Inspect the Circuit Breaker Thresholds in CDS**
```bash
istioctl proxy-config cluster deploy/client-toolbox.orderflow \
  --fqdn payment-service.orderflow.svc.cluster.local --subset v1 -o json | grep -A 10 "circuitBreakers"
```
You will see `"maxConnections": 1` and `"maxPendingRequests": 1`.

### 4. Root Cause & Fix
The `DestinationRule` set `maxConnections: 1` and `http1MaxPendingRequests: 1`. Raise the connection pool limits to realistic production thresholds (e.g., `maxConnections: 100`, `http1MaxPendingRequests: 50`):

```bash
kubectl patch destinationrule payment-service-dr -n orderflow --type='merge' \
  -p '{"spec":{"trafficPolicy":{"connectionPool":{"tcp":{"maxConnections":100},"http":{"http1MaxPendingRequests":50,"maxRequestsPerConnection":100}}}}}'
```

---

## Scenario 4: The Silent Egress Blackhole (`502/503 NR`)

### 1. Inject the Outage
To optimize Envoy memory usage, the platform team deployed a `Sidecar` CRD for `order-service`:
```bash
kubectl apply -f manifests/scenario-4-sidecar-egress-blackhole.yaml
```

### 2. Observe the Symptom
Calling `payment-service` directly works, and `order-service` can still reach `payment-service`, **but** full checkout requests through `frontend` -> `order-service` (which calls both `payment-service` and `inventory-service`) now fail!
```bash
kubectl exec -n orderflow deploy/client-toolbox -c curl -- \
  curl -i http://frontend.orderflow.svc.cluster.local/
```
And if you test calling `inventory-service` from inside the `order-service-v1` pod's network namespace:
```bash
kubectl logs -n orderflow deploy/order-service-v1 -c istio-proxy --tail=10
```
You see:
```text
"GET / HTTP/1.1" 502 - direct_response - "-" 0 0 0 - "-" ... "BlackHoleCluster" -
```
(Or `503 NR` depending on the port/host match). Notice the target cluster is **`BlackHoleCluster`**!

### 3. Step-by-Step Diagnostic Investigation

**Step A: Inspect `order-service-v1`'s Known Clusters in CDS**
```bash
istioctl proxy-config cluster deploy/order-service-v1.orderflow
```
Look closely at the list of `outbound` clusters on `order-service-v1`:
- `outbound|8080||payment-service.orderflow.svc.cluster.local` is present.
- **`inventory-service.orderflow.svc.cluster.local` is completely missing from CDS!**

**Step B: Inspect the `Sidecar` CRD in `orderflow`**
```bash
kubectl get sidecar -n orderflow -o yaml
```
Look at `spec.egress[0].hosts`:
```yaml
egress:
  - hosts:
      - "istio-system/*"
      - "orderflow/payment-service.orderflow.svc.cluster.local"
```
Because `order-service-sidecar` explicitly listed only `payment-service` and set `outboundTrafficPolicy.mode: REGISTRY_ONLY`, `istiod` stripped `inventory-service` from `order-service`'s xDS configuration! Any outbound HTTP call on port `8080` with `Host: inventory-service:8080` fails to match a virtual host in RDS and falls through to Envoy's `BlackHoleCluster`.

### 4. Root Cause & Fix
Add `orderflow/inventory-service.orderflow.svc.cluster.local` (or `orderflow/*`) to the `Sidecar` egress hosts list:

```bash
kubectl patch sidecar order-service-sidecar -n orderflow --type='json' \
  -p='[{"op": "add", "path": "/spec/egress/0/hosts/-", "value": "orderflow/inventory-service.orderflow.svc.cluster.local"}]'

# Confirm inventory-service is now back in order-service-v1's CDS table
istioctl proxy-config cluster deploy/order-service-v1.orderflow --fqdn inventory-service.orderflow.svc.cluster.local

# Verify end-to-end request succeeds
kubectl exec -n orderflow deploy/client-toolbox -c curl -- \
  curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" http://frontend.orderflow.svc.cluster.local/
```

---

## Scenario 5: The Protocol Sniffing Trap (`503 UC / protocol_error`)

### 1. Inject the Outage
Someone updated the `inventory-service` Kubernetes `Service` manifest and named the port `grpc-inventory` (`appProtocol: grpc`), even though `inventory-service` is a standard HTTP/1.1 REST server:
```bash
kubectl apply -f manifests/scenario-5-wrong-port-protocol.yaml
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

### 3. Step-by-Step Diagnostic Investigation

**Step A: Check the Envoy Access Logs**
```bash
kubectl logs -n orderflow deploy/client-toolbox -c istio-proxy --tail=5
```
Output:
```text
"GET / HTTP/1.1" 503 UC,URX upstream_reset_before_response_started{protocol_error} - "-" 0 145 12 - "-" ... "outbound|8080||inventory-service.orderflow.svc.cluster.local"
```
Notice `503 UC,URX` with exact details: **`upstream_reset_before_response_started{protocol_error}`**.

**Step B: Inspect the Upstream HTTP Protocol Options in CDS**
```bash
istioctl proxy-config cluster deploy/client-toolbox.orderflow \
  --fqdn inventory-service.orderflow.svc.cluster.local -o json | grep -A 8 "http2ProtocolOptions"
```
Because the Service port name starts with `grpc-` (and `appProtocol: grpc`), `istiod` programmed Envoy with `http2ProtocolOptions` on the upstream cluster. Envoy upgraded the outbound connection to HTTP/2 (`PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n`), which the HTTP/1.1 upstream rejected as malformed HTTP (`protocol_error`).

### 4. Root Cause & Fix
Rename the `inventory-service` port to `http-inventory` and set `appProtocol: http`:

```bash
kubectl patch service inventory-service -n orderflow --type='json' \
  -p='[{"op": "replace", "path": "/spec/ports/0/name", "value": "http-inventory"}, {"op": "replace", "path": "/spec/ports/0/appProtocol", "value": "http"}]'

# Clean up the War-Room scenario manifests
kubectl delete -f manifests/scenario-1-broken-subset-nr.yaml \
               -f manifests/scenario-2-mtls-conflict-uf.yaml \
               -f manifests/scenario-3-aggressive-cb-uo.yaml \
               -f manifests/scenario-4-sidecar-egress-blackhole.yaml --ignore-not-found

# Verify 200 OK
kubectl exec -n orderflow deploy/client-toolbox -c curl -- \
  curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" http://frontend.orderflow.svc.cluster.local/
```

---

## Part 2: Zero-Downtime Revision-Based Canary Control Plane Upgrade

Now that the `orderflow` platform is healthy, you will perform a zero-downtime canary control plane upgrade by running a second `istiod` revision (`1-24-canary`) alongside the default control plane, migrating `orderflow` workloads to it, and verifying xDS connectivity.

### Step 1: Install the Canary Control Plane Revision (`1-24-canary`)
```bash
istioctl install --set revision=1-24-canary --set profile=default -y
```
Verify that two `istiod` deployments now run side-by-side in `istio-system`:
```bash
kubectl get deployments,svc -n istio-system -l app=istiod
```
Check the active control plane revisions in the cluster:
```bash
istioctl tag list
kubectl get mutatingwebhookconfigurations | grep istio
```

### Step 2: Migrate the `orderflow` Namespace to the Canary Revision
Replace the legacy `istio-injection=enabled` label on `orderflow` with `istio.io/rev=1-24-canary`:
```bash
kubectl label namespace orderflow istio-injection- istio.io/rev=1-24-canary --overwrite
```
 Notice that relabeling the namespace does **not** immediately restart existing pods—this gives you full control over the blast radius.

### Step 3: Migrate Workloads Gradually & Verify Inter-Revision mTLS
First, restart **only** `payment-service-v1` and `payment-service-v2` so that half of your mesh runs on the canary control plane (`istiod-1-24-canary`) while `frontend` and `order-service` remain on the original `istiod`:
```bash
kubectl rollout restart deployment/payment-service-v1 deployment/payment-service-v2 -n orderflow
kubectl rollout status deployment/payment-service-v1 deployment/payment-service-v2 -n orderflow
```
Run `istioctl proxy-status` to see proxies split across both control planes:
```bash
istioctl proxy-status
```
Notice how `payment-service-v1` and `v2` show `ISTIOD: istiod-1-24-canary-...`, while `order-service` and `frontend` remain on the original `istiod-...`!

Verify that cross-revision mTLS traffic works with zero errors:
```bash
kubectl exec -n orderflow deploy/client-toolbox -c curl -- \
  curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" http://frontend.orderflow.svc.cluster.local/
```

### Step 4: Complete the Migration (or Rollback to `istio-injection=enabled`)
Migrate the remaining deployments in `orderflow`:
```bash
kubectl rollout restart deployment -n orderflow
kubectl rollout status deployment -n orderflow
istioctl proxy-status
```
*(Optional Cleanup)*: To restore the cluster to the standard single-revision state for Module 10 and remove the canary revision:
```bash
kubectl label namespace orderflow istio.io/rev- istio-injection=enabled --overwrite
kubectl rollout restart deployment -n orderflow
kubectl rollout status deployment -n orderflow
istioctl uninstall --revision=1-24-canary -y
```
