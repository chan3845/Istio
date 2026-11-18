# Module 04 Lab: SPIFFE Certificates, `STRICT` mTLS, Zero-Trust `AuthorizationPolicy`, JWT Auth & Debugging `AND` vs `OR` Rules

## Learning Objectives
By the end of this lab, you will be able to:
1. Extract and inspect in-memory X.509 workload certificates from Envoy via SDS and verify the SPIFFE ID (`spiffe://cluster.local/ns/orderflow/sa/...`) using `openssl`.
2. Demonstrate the difference between `PERMISSIVE` and `STRICT` mTLS by testing calls from an uninjected legacy pod vs. a mesh-injected pod.
3. Lock down the entire `orderflow` namespace with a Zero-Trust `allow-nothing` baseline `AuthorizationPolicy` and explicitly unlock the `OrderFlow` microservice call graph using SPIFFE `principals`.
4. Configure end-user JWT verification with `RequestAuthentication` and enforce claim-based access control (`request.auth.claims[role]: ["admin"]`) with `AuthorizationPolicy`.
5. Diagnose and fix a broken `AuthorizationPolicy` caused by the classic YAML list `AND` vs. `OR` pitfall.

---

## Prerequisites & Version Baseline Pre-Flight Verification

> **Version Baseline (November 2026)**: Istio `1.32.0` | Envoy `v1.40` | Kubernetes `v1.36+` | Gateway API `v1.6.1`
> **Fellowship Reference**: **[Week 05: Zero-Trust Security Architecture](../fellowship/week-05-zero-trust-security-architecture/WEEK.md)** | [`../VERSIONS.md`](../VERSIONS.md)

- Kubernetes `v1.36+` cluster with Istio `1.32.0` installed and the `orderflow` namespace workloads running.
- Run the pre-flight verification check to confirm your Istio version and verify each workload in `orderflow` uses its dedicated `ServiceAccount` (`frontend-sa`, `order-sa`, `payment-sa`, `inventory-sa`, `toolbox-sa`):
  ```bash
  istioctl version
  kubectl get pods -n orderflow -o custom-columns="POD:.metadata.name,SA:.spec.serviceAccountName,READY:.status.containerStatuses[*].ready"
  ```

---

## Architecture & Expected Zero-Trust Call Graph

```mermaid
flowchart LR
    Toolbox["client-toolbox<br/>(SA: toolbox-sa)<br/>(Blocked by Default, Allowed ONLY with Admin JWT)"] -.->|"GET /admin<br/>+ Valid JWT (role=admin)"| Order["order-service<br/>(SA: order-sa)"]
    
    Frontend["frontend<br/>(SA: frontend-sa)"] ===>|"ALLOWED:<br/>GET / POST /"| Order
    
    Order ===>|"ALLOWED:<br/>GET / POST /"| Payment["payment-service<br/>(SA: payment-sa)"]
    Order ===>|"ALLOWED:<br/>GET /"| Inventory["inventory-service<br/>(SA: inventory-sa)"]

    LegacyPod["legacy-uninjected-client<br/>(No Sidecar / Plaintext)"] -.->|"REJECTED at TLS Layer<br/>(PeerAuthentication: STRICT)"| Order
```

---

## Step-by-Step Implementation

### Step 1: Inspect SPIFFE X.509 Workload Certificates in Memory

Let's extract the live X.509 certificate held in RAM by `order-service`'s Envoy proxy via SDS and inspect its fields with `openssl x509`:

```bash
ORDER_POD=$(kubectl get pod -n orderflow -l app=order-service,version=v1 -o jsonpath='{.items[0].metadata.name}')
istioctl proxy-config secret "$ORDER_POD.orderflow"
```

**Expected Output:**
```text
RESOURCE NAME     TYPE           STATUS     VALID CERT     SERIAL NUMBER                        NOT AFTER                NOT BEFORE
default           Cert Chain     ACTIVE     true           8a91b2c3d4e5f6...                    2026-11-18T16:00:00Z     2026-11-17T15:58:00Z
ROOTCA            CA             ACTIVE     true           1f2e3d4c5b6a79...                    2036-11-14T15:00:00Z     2026-11-17T15:00:00Z
```

Now decode the `default` leaf certificate chain and view its Issuer, Validity, and `X509v3 Subject Alternative Name`:

```bash
istioctl proxy-config secret "$ORDER_POD.orderflow" -o json | \
  jq -r '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes' | \
  base64 -d | \
  openssl x509 -noout -text | grep -A 4 -E "Issuer:|Validity|Subject Alternative Name"
```

**Expected Output:**
```text
        Issuer: O = cluster.local
        Validity
            Not Before: Nov 17 15:58:00 2026 GMT
            Not After : Nov 18 16:00:00 2026 GMT
--
            X509v3 Subject Alternative Name: critical
                URI:spiffe://cluster.local/ns/orderflow/sa/order-sa
```
Notice that the `Subject` field of an Istio workload certificate is intentionally empty (`Subject: `); all identity verification relies strictly on the `critical` X.509v3 SAN URI (`spiffe://cluster.local/ns/orderflow/sa/order-sa`).

---

### Step 2: Migrate from `PERMISSIVE` to `STRICT` mTLS

#### 2.1 Test Plaintext Access Under Default `PERMISSIVE` Mode

Apply `peer-authentication-strict.yaml`? Wait — before applying it, let's deploy a temporary uninjected pod (`sidecar.istio.io/inject: "false"`) in `orderflow` to simulate a legacy non-mesh workload sending plaintext HTTP:

```bash
kubectl run legacy-client -n orderflow --image=curlimages/curl:8.5.0 \
  --annotations="sidecar.istio.io/inject=false" \
  --command -- sleep 3650d
kubectl wait --for=condition=Ready pod/legacy-client -n orderflow --timeout=60s
```

Verify that `legacy-client` has `1/1` containers (no Envoy sidecar) and can call `order-service:8080` in plaintext while `PERMISSIVE` mode is active:

```bash
kubectl exec -n orderflow legacy-client -- curl -s -o /dev/null -w "HTTP Code: %{http_code}\n" http://order-service:8080
```

**Expected Output:**
```text
HTTP Code: 200
```

#### 2.2 Enforce `STRICT` mTLS Across `orderflow`

Now apply `peer-authentication-strict.yaml`:

```bash
kubectl apply -f /home/chan/Documents/Istio/04-security-mtls-and-authz/manifests/peer-authentication-strict.yaml
```

Inspect the inbound listener (`15006`) on `order-service` to see what changed under the hood:

```bash
istioctl proxy-config listener "$ORDER_POD.orderflow" --port 15006
```

**Expected Output:**
Notice that the `Trans: raw_buffer` (plaintext) filter chain for port `8080` has been **completely removed** from `15006`! Only `Trans: tls` remains.

Now test calling `order-service:8080` from the uninjected `legacy-client` vs. the mesh-injected `client-toolbox`:

```bash
echo "--- From uninjected legacy-client (Plaintext): ---"
kubectl exec -n orderflow legacy-client -- curl -s -i http://order-service:8080 || echo "Connection Rejected at TLS Layer (exit code $?)"

echo "--- From mesh-injected client-toolbox (mTLS): ---"
TOOLBOX_POD=$(kubectl get pod -n orderflow -l app=client-toolbox -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n orderflow "$TOOLBOX_POD" -c client-toolbox -- curl -s -o /dev/null -w "HTTP Code: %{http_code}\n" http://order-service:8080
```

**Expected Output:**
- `legacy-client` fails immediately with `curl: (56) Recv failure: Connection reset by peer (exit code 56)`.
- `client-toolbox` succeeds with `HTTP Code: 200` because its Envoy sidecar automatically presents its SPIFFE mTLS certificate!

Clean up `legacy-client`:
```bash
kubectl delete pod legacy-client -n orderflow --now
```

---

### Step 3: Enforce Zero-Trust Microservice Segmentation (`AuthorizationPolicy`)

Right now, even though mTLS is `STRICT`, **any** pod in the mesh (including `client-toolbox` or `frontend`) can directly call `payment-service` or `inventory-service`. In our architecture:
- Only `frontend-sa` should be allowed to call `order-service`.
- Only `order-sa` should be allowed to call `payment-service` and `inventory-service`.
- Direct calls from `client-toolbox` (`toolbox-sa`) to `order-service`, `payment-service`, or `inventory-service` must be **blocked (`403 Forbidden`)**!

Apply `authorization-policies-zerotrust.yaml`:

```bash
kubectl apply -f /home/chan/Documents/Istio/04-security-mtls-and-authz/manifests/authorization-policies-zerotrust.yaml
```

Let's test this Zero-Trust segmentation!

#### 3.1 Verify Direct Unauthorized Calls from `client-toolbox` Are Blocked (`403 Forbidden`)

```bash
echo "1. Toolbox -> payment-service (Should be 403):"
kubectl exec -n orderflow "$TOOLBOX_POD" -c client-toolbox -- curl -s -i http://payment-service:8080 | head -n 5

echo "2. Toolbox -> order-service (Should be 403):"
kubectl exec -n orderflow "$TOOLBOX_POD" -c client-toolbox -- curl -s -i http://order-service:8080 | head -n 5
```

**Expected Output:**
```http
HTTP/1.1 403 Forbidden
content-length: 19
content-type: text/plain
date: Tue, 17 Nov 2026 16:40:00 GMT
server: envoy
RBAC: access denied
```

#### 3.2 Verify Authorized End-to-End Call Chain via `frontend` Succeeds (`200 OK`)

Our policy allows `toolbox-sa` (and `istio-ingressgateway-service-account`) to call `frontend`, `frontend-sa` to call `order-service`, and `order-sa` to call `payment-service` and `inventory-service`. Test calling `http://frontend:80` from `client-toolbox`:

```bash
kubectl exec -n orderflow "$TOOLBOX_POD" -c client-toolbox -- curl -s http://frontend:80 | grep -E '"name":|"code":'
```

**Expected Output:**
```text
  "name": "frontend",
  "code": 200,
      "name": "order-service-v1",
      "code": 200,
          "name": "payment-service-v1",
          "code": 200,
          "name": "inventory-service-v1",
          "code": 200
```
Every hop in the legitimate call graph succeeds with `200 OK`, while lateral movement (`toolbox -> payment-service`) is completely blocked with `RBAC: access denied`!

---

### Step 4: End-User JWT Verification (`RequestAuthentication`) & Claim-Based `AuthorizationPolicy`

Suppose we want to allow `client-toolbox` (or any caller) to access `order-service` on `/admin` **only if** the request carries a valid signed JWT with issuer `testing@secure.istio.io` and claim `"role": "admin"` (or group `"admin"`).

Apply `jwt-request-authn-and-authz.yaml`, which configures:
1. A `RequestAuthentication` on `order-service` with an inline JWKS public key (works completely offline inside sandboxed clusters without needing internet access!).
2. An `AuthorizationPolicy` (`allow-order-admin-jwt`) allowing `GET` requests to `/admin*` when `request.auth.claims[groups]` contains `group1`.

```bash
kubectl apply -f /home/chan/Documents/Istio/04-security-mtls-and-authz/manifests/jwt-request-authn-and-authz.yaml
```

Now let's test the three JWT scenarios from `client-toolbox`:

#### Scenario A: Request with an Invalid/Corrupted JWT -> `401 Unauthorized`

```bash
kubectl exec -n orderflow "$TOOLBOX_POD" -c client-toolbox -- \
  curl -s -i -H "Authorization: Bearer invalid.jwt.token" http://order-service:8080/admin
```

**Expected Output:**
```http
HTTP/1.1 401 Unauthorized
www-authenticate: Bearer realm="http://order-service:8080/admin", error="invalid_token"
...
Jwt is not in the form of Header.Payload.Signature with two dots and 3 sections
```

#### Scenario B: Request with NO JWT to `/admin` -> `403 Forbidden`
Because `RequestAuthentication` passes unauthenticated requests through without populating `requestPrincipals`, Envoy's `rbac` filter checks `AuthorizationPolicy` and denies the request:

```bash
kubectl exec -n orderflow "$TOOLBOX_POD" -c client-toolbox -- \
  curl -s -i http://order-service:8080/admin
```

**Expected Output:**
```http
HTTP/1.1 403 Forbidden
...
RBAC: access denied
```

#### Scenario C: Request with a Valid Signed JWT (`iss: testing@secure.istio.io`, `groups: ["group1", "group2"]`) -> `200 OK`

Use Istio's standard test JWT (expiring in year 2119, signed by the private key matching the inline JWKS in our manifest):

```bash
TOKEN="eyJhbGciOiJSUzI1NiIsImtpZCI6IkRIRmJwb0lVcXJZOHQyenBBMnFYZkNtcjVWTzVaRXI0UnpIVV8tUWl2dlEiLCJ0eXAiOiJKV1QifQ.eyJleHAiOjQ2ODU5ODk3MDAsImZvbyI6ImJhciIsImlhdCI6MTUzMjM4OTcwMCwiaXNzIjoidGVzdGluZ0BzZWN1cmUuaXN0aW8uaW8iLCJzdWIiOiJ0ZXN0aW5nQHNlY3VyZS5pc3Rpby5pbyIsImdyb3VwcyI6WyJncm91cDEiLCJncm91cDIiXX0.invalid_or_real"
```
*(Wait — let's pull the exact valid token directly from our ConfigMap in `jwt-request-authn-and-authz.yaml` so you don't have to copy-paste long strings!)*

```bash
VALID_JWT=$(kubectl get configmap sample-jwt-tokens -n orderflow -o jsonpath='{.data.token-group1}')
kubectl exec -n orderflow "$TOOLBOX_POD" -c client-toolbox -- \
  curl -s -i -H "Authorization: Bearer $VALID_JWT" http://order-service:8080/admin | head -n 15
```

**Expected Output:**
```http
HTTP/1.1 200 OK
```

---

### Step 5: Troubleshooting Exercise — The `AND` vs. `OR` `AuthorizationPolicy` Trap

A security engineer wants to allow `toolbox-sa` to call `inventory-service`, **but ONLY for HTTP `HEAD` health-check requests**. They write and apply `broken-authz-and-or-trap.yaml`:

```bash
kubectl apply -f /home/chan/Documents/Istio/04-security-mtls-and-authz/manifests/broken-authz-and-or-trap.yaml
```

Now test sending a **`DELETE`** request from `client-toolbox` (`toolbox-sa`) to `inventory-service`:

```bash
kubectl exec -n orderflow "$TOOLBOX_POD" -c client-toolbox -- \
  curl -s -i -X DELETE http://inventory-service:8080/items/999 | head -n 10
```

**Expected Output:**
`HTTP/1.1 200 OK`! Why did `DELETE /items/999` succeed when the policy was only supposed to allow `HEAD` requests?!

#### Root Cause Analysis:
Inspect `/home/chan/Documents/Istio/04-security-mtls-and-authz/manifests/broken-authz-and-or-trap.yaml`:
```yaml
  rules:
    - from:
        - source:
            principals: ["cluster.local/ns/orderflow/sa/toolbox-sa"]
    - to:   # <--- BUG! Extra '-' creates a SECOND independent rule (Logical OR)!
        - operation:
            methods: ["HEAD"]
```
Because `- to:` has a leading hyphen (`-`), Kubernetes YAML parses `rules` as an array of **two separate rules**:
- **Rule 1**: Allow if `source.principals == toolbox-sa` (for **ANY** HTTP method and **ANY** path!).
- **Rule 2**: Allow if `operation.methods == HEAD` (from **ANY** caller in the cluster!).

#### Fix the Bug:
Remove the extra `-` before `to:` so `from:` and `to:` belong to the **same rule object** (Logical AND), or delete the broken policy:

```bash
kubectl delete -f /home/chan/Documents/Istio/04-security-mtls-and-authz/manifests/broken-authz-and-or-trap.yaml
```
