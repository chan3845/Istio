# Module 03 Lab: Ingress Gateways (TLS), Kubernetes Gateway API, `ServiceEntry` TLS Origination & Egress Gateways

## Learning Objectives
By the end of this lab, you will be able to:
1. Generate a TLS certificate, store it in `istio-system`, and expose `frontend` and `order-service` securely using an Istio `Gateway` (`SIMPLE` TLS termination) and `VirtualService`.
2. Inspect the standalone Envoy listeners and SDS secrets inside `istio-ingressgateway`.
3. Migrate the North-South configuration to the modern **Kubernetes Gateway API** (`Gateway` + `HTTPRoute`).
4. Lock down outbound mesh traffic using `outboundTrafficPolicy.mode: REGISTRY_ONLY` (`BlackHoleCluster`).
5. Register an external service (`httpbin.org`) using a `ServiceEntry`, configure **TLS Origination** (`HTTP :80` -> `HTTPS :443`) via a `DestinationRule`, and route external traffic through `istio-egressgateway`.

---

## Prerequisites
- Kubernetes cluster with `istiod`, `istio-ingressgateway`, and `istio-egressgateway` installed in `istio-system`.
  *(If `istio-egressgateway` is not yet deployed in `istio-system`, you can enable it via `istioctl install --set profile=demo --skip-confirmation` or `--set components.egressGateways[0].name=istio-egressgateway --set components.egressGateways[0].enabled=true`).*
- Verify the gateway pods in `istio-system`:
  ```bash
  kubectl get pods -n istio-system -l 'istio in (ingressgateway, egressgateway)'
  ```

---

## Architecture & Expected Traffic Flow

```mermaid
flowchart TB
    subgraph NorthSouthIngress["Part 1 & 2: North-South Ingress (TLS Termination)"]
        ExtUser["External Client (curl --resolve)"] -->|"HTTPS :443<br/>Host: orderflow.example.com"| IGW["istio-ingressgateway<br/>(Terminates TLS via SDS Secret)"]
        IGW -->|"URI / -> Mesh mTLS"| Frontend["frontend (:8080)"]
        IGW -->|"URI /orders -> Mesh mTLS"| OrderSvc["order-service (:8080)"]
    end

    subgraph ControlledEgress["Part 3 & 4: Controlled Egress (REGISTRY_ONLY + Egress Gateway)"]
        Toolbox["client-toolbox / payment-service"] -->|"1. Plain HTTP :80<br/>http://httpbin.org/headers"| Sidecar["Workload Envoy Sidecar (:15001)"]
        Sidecar -->|"2. Internal Mesh mTLS :443"| EGW["istio-egressgateway<br/>(istio-system)"]
        EGW -->|"3. TLS Origination (HTTPS :443)<br/>SNI: httpbin.org"| Httpbin["External Internet<br/>https://httpbin.org:443"]
    end
```

---

## Step-by-Step Implementation

### Step 1: Expose `OrderFlow` via Classic Istio `Gateway` with TLS Termination

#### 1.1 Generate an X.509 Certificate and Create the TLS Secret in `istio-system`

Remember that for a classic Istio `Gateway` targeting `istio-ingressgateway`, the TLS secret must reside in the **same namespace as the gateway pod (`istio-system`)**:

```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -subj "/CN=orderflow.example.com/O=OrderFlow Inc" \
  -addext "subjectAltName = DNS:orderflow.example.com" \
  -keyout /tmp/orderflow.key \
  -out /tmp/orderflow.crt

kubectl create secret tls orderflow-tls-credential \
  --key=/tmp/orderflow.key \
  --cert=/tmp/orderflow.crt \
  -n istio-system --dry-run=client -o yaml | kubectl apply -f -
```

#### 1.2 Apply the Istio `Gateway` and `VirtualService`

Apply `ingress-gateway-tls.yaml`, which configures:
- HTTP port `80` with `httpsRedirect: true` (automatically returns `301 Moved Permanently` to `https://`).
- HTTPS port `443` with `tls.mode: SIMPLE` and `credentialName: orderflow-tls-credential`.
- A `VirtualService` routing `/orders` (rewritten to `/`) to `order-service:8080` and `/` to `frontend:80`.

```bash
kubectl apply -f /home/chan/Documents/Istio/03-gateways-ingress-and-egress/manifests/ingress-gateway-tls.yaml
```

#### 1.3 Inspect SDS & Listeners on `istio-ingressgateway`

Verify that `istio-ingressgateway` fetched `orderflow-tls-credential` via SDS and opened listener `8443` (or `443`):

```bash
IGW_POD=$(kubectl get pod -n istio-system -l app=istio-ingressgateway -o jsonpath='{.items[0].metadata.name}')
istioctl proxy-config secret "$IGW_POD.istio-system"
istioctl proxy-config listener "$IGW_POD.istio-system"
```

**Expected Output (`secret`):**
```text
RESOURCE NAME                        TYPE           STATUS     VALID CERT     SERIAL NUMBER                        NOT AFTER                NOT BEFORE
default                              Cert Chain     ACTIVE     true           ...                                  2026-11-18T15:50:00Z     2026-11-17T15:48:00Z
kubernetes://orderflow-tls-credential Cert Chain     ACTIVE     true           ...                                  2027-11-17T15:50:00Z     2026-11-17T15:50:00Z
```

#### 1.4 Test External HTTP -> HTTPS Redirect and TLS Routing

Determine the Ingress IP and ports (works with LoadBalancer IP or NodePort):

```bash
export INGRESS_HOST=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
if [ -z "$INGRESS_HOST" ]; then
  export INGRESS_HOST=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}')
  export INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')
  export SECURE_INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')
else
  export INGRESS_PORT=80
  export SECURE_INGRESS_PORT=443
fi
echo "INGRESS_HOST=$INGRESS_HOST | HTTP=$INGRESS_PORT | HTTPS=$SECURE_INGRESS_PORT"
```

First, test plain HTTP on `$INGRESS_PORT` to verify the automatic `301 Moved Permanently` HTTPS redirect:

```bash
curl -s -I -H "Host: orderflow.example.com" "http://$INGRESS_HOST:$INGRESS_PORT/"
```

**Expected Output:**
```http
HTTP/1.1 301 Moved Permanently
location: https://orderflow.example.com/
server: istio-envoy
```

Now test HTTPS using `--resolve` and `--cacert /tmp/orderflow.crt` against `/` (`frontend`) and `/orders` (`order-service`):

```bash
curl -s --resolve "orderflow.example.com:$SECURE_INGRESS_PORT:$INGRESS_HOST" \
  --cacert /tmp/orderflow.crt \
  "https://orderflow.example.com:$SECURE_INGRESS_PORT/" | grep -E '"name":|"code":'

curl -s --resolve "orderflow.example.com:$SECURE_INGRESS_PORT:$INGRESS_HOST" \
  --cacert /tmp/orderflow.crt \
  "https://orderflow.example.com:$SECURE_INGRESS_PORT/orders" | grep -E '"name":|"code":'
```

**Expected Output:**
- `/` returns the full upstream call graph starting from `frontend`.
- `/orders` bypasses `frontend` and hits `order-service` directly!

---

### Step 2: Migrate to the Modern Kubernetes Gateway API (`Gateway` + `HTTPRoute`)

Now let's see how the Kubernetes Gateway API (`gateway.networking.k8s.io/v1`) replaces Istio's custom `Gateway` and `VirtualService` CRDs.

Ensure the Kubernetes Gateway API CRDs are installed on your cluster:

```bash
kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1 || \
  kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml
```

Create the TLS secret directly inside the `orderflow` namespace (because with Kubernetes Gateway API, our `Gateway` resource in `orderflow` references secrets in its own namespace!):

```bash
kubectl create secret tls orderflow-gwapi-tls \
  --key=/tmp/orderflow.key \
  --cert=/tmp/orderflow.crt \
  -n orderflow --dry-run=client -o yaml | kubectl apply -f -
```

Apply `k8s-gateway-api.yaml`:

```bash
kubectl apply -f /home/chan/Documents/Istio/03-gateways-ingress-and-egress/manifests/k8s-gateway-api.yaml
```

Inspect what `istiod` automatically created in `orderflow` when it saw `gatewayClassName: istio`:

```bash
kubectl get gateway,httproute,deploy,svc -n orderflow | grep -E "NAME|orderflow-k8s"
```

**Expected Output:**
`istiod` automatically provisioned a dedicated `Deployment` (`orderflow-k8s-gateway-istio`) and `Service` (`orderflow-k8s-gateway-istio`) inside `orderflow`!

---

### Step 3: Lock Down Egress with `REGISTRY_ONLY` & Register External Services (`ServiceEntry` + TLS Origination)

#### 3.1 Verify Default `ALLOW_ANY` Behavior

By default, any pod in `orderflow` can reach arbitrary external websites via Envoy's `PassthroughCluster`. Test calling `http://httpbin.org/headers` from `client-toolbox`:

```bash
TOOLBOX_POD=$(kubectl get pod -n orderflow -l app=client-toolbox -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n orderflow "$TOOLBOX_POD" -c client-toolbox -- curl -s -I http://httpbin.org/headers | head -n 5
```

**Expected Output:**
`HTTP/1.1 200 OK`

#### 3.2 Switch `meshConfig.outboundTrafficPolicy.mode` to `REGISTRY_ONLY`

Patch the `istio` ConfigMap in `istio-system` (or update via `istioctl`) to set `outboundTrafficPolicy.mode: REGISTRY_ONLY`:

```bash
kubectl get configmap istio -n istio-system -o yaml | \
  sed 's/mode: ALLOW_ANY/mode: REGISTRY_ONLY/g' | \
  kubectl apply -f -
```
*(If `outboundTrafficPolicy` was not explicitly in the ConfigMap yet, patch it in):*
```bash
kubectl patch configmap istio -n istio-system --type merge -p '{"data":{"mesh":"outboundTrafficPolicy:\n  mode: REGISTRY_ONLY\n"}}'
```

Wait 5 seconds for `istiod` to push the updated `virtualOutbound` listener configuration to Envoy, then test calling `http://httpbin.org/headers` again:

```bash
kubectl exec -n orderflow "$TOOLBOX_POD" -c client-toolbox -- curl -i -s http://httpbin.org/headers
```

**Expected Output:**
```http
HTTP/1.1 502 Bad Gateway
date: Tue, 17 Nov 2026 16:25:00 GMT
server: envoy
content-length: 0
```
Check the Envoy access logs on `client-toolbox` and you will see **`UH` / `BlackHoleCluster`** — external access to unregistered domains is now completely blocked!

#### 3.3 Apply `ServiceEntry` + `DestinationRule` for Sidecar TLS Origination

Now apply `service-entry-tls-origination.yaml`, which:
1. Registers `httpbin.org` in Istio's Service Registry on ports `80` (`HTTP`) and `443` (`HTTPS`) with `resolution: DNS`.
2. Rewrites outbound plaintext calls to `http://httpbin.org:80` so Envoy routes them to port `443` and **originates TLS (`tls.mode: SIMPLE`)** on behalf of the application.

```bash
kubectl apply -f /home/chan/Documents/Istio/03-gateways-ingress-and-egress/manifests/service-entry-tls-origination.yaml
```

Now make a **plaintext HTTP** request (`http://httpbin.org/headers`) from `client-toolbox`:

```bash
kubectl exec -n orderflow "$TOOLBOX_POD" -c client-toolbox -- curl -s http://httpbin.org/headers
```

**Expected Output:**
```json
{
  "headers": {
    "Accept": "*/*",
    "Host": "httpbin.org",
    "User-Agent": "curl/8.5.0",
    "X-Envoy-Attempt-Count": "1",
    "X-Forwarded-Proto": "https"
  }
}
```
Look closely at `"X-Forwarded-Proto": "https"`! Even though `curl` sent plaintext `http://httpbin.org/headers`, the local Envoy sidecar encrypted the request into HTTPS `:443` before sending it over the internet.

---

### Step 4: Route External Traffic Through the Dedicated `istio-egressgateway`

In production, we don't want application pods connecting directly to external internet IPs; we want all external traffic to funnel through `istio-egressgateway` over internal mTLS first, and let `istio-egressgateway` originate the external HTTPS connection.

Apply `egress-gateway-routing.yaml`:

```bash
kubectl apply -f /home/chan/Documents/Istio/03-gateways-ingress-and-egress/manifests/egress-gateway-routing.yaml
```

Now send a request from `client-toolbox` to `http://httpbin.org/headers`:

```bash
kubectl exec -n orderflow "$TOOLBOX_POD" -c client-toolbox -- curl -s http://httpbin.org/headers
```

Verify in the `istio-egressgateway` logs that the request actually traversed the Egress Gateway pod in `istio-system`:

```bash
kubectl logs -n istio-system -l app=istio-egressgateway --tail=10
```

**Expected Output (`istio-egressgateway` access log):**
```text
[2026-11-17T16:30:15.412Z] "GET /headers HTTP/2" 200 - via_upstream - "-" 0 385 192 191 "-" "curl/8.5.0" "d4e5f6a7-..." "httpbin.org" "54.236.112.90:443" outbound|443||httpbin.org 10.244.1.28:51422 10.244.1.28:8443 10.244.1.12:39814 httpbin.org -
```

#### Clean Up Egress Policy for Subsequent Labs
Restore `outboundTrafficPolicy.mode: ALLOW_ANY` and remove the egress gateway routing rules so subsequent modules start cleanly:

```bash
kubectl delete -f /home/chan/Documents/Istio/03-gateways-ingress-and-egress/manifests/egress-gateway-routing.yaml
kubectl delete -f /home/chan/Documents/Istio/03-gateways-ingress-and-egress/manifests/service-entry-tls-origination.yaml
kubectl patch configmap istio -n istio-system --type merge -p '{"data":{"mesh":"outboundTrafficPolicy:\n  mode: ALLOW_ANY\n"}}'
```

---

## Troubleshooting Exercises

### Exercise 1: Why Does `Gateway` Return `Connection Reset` or `SSL Handshake Failed`?
If `curl https://orderflow.example.com` fails during the TLS handshake:
1. **Check Secret Namespace**: Run `istioctl proxy-config secret <ingress-pod>.istio-system`. If the secret is missing or stuck in `WARMING`, verify that `orderflow-tls-credential` was created in **`istio-system`** (where the gateway pod runs), *not* in `orderflow`!
2. **Check SNI Hostname Match**: If you run `curl https://<INGRESS_IP>/` without `--resolve` (only passing `-H "Host: orderflow.example.com"`), the HTTP `Host` header is encrypted *inside* TLS, so the unencrypted TLS `ClientHello` SNI extension is empty! Because the Gateway listener filter chain matches `hosts: ["orderflow.example.com"]` via SNI, Envoy resets the TLS handshake before ever seeing the HTTP `Host` header. Always use `--resolve orderflow.example.com:443:<INGRESS_IP>` when testing TLS gateways by IP!
