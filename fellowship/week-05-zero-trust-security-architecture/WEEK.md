[Fellowship Portal](../../README.md) · [Handbook](../../FELLOWSHIP_HANDBOOK.md) · [Progression Dashboard](../../PROGRESSION_DASHBOARD.md) · [<- Previous Week](../week-04-edge-gateways-and-controlled-egress/WEEK.md) · **Week 05 of 10** · [Next Week ->](../week-06-resilience-and-chaos-engineering/WEEK.md)

# Week 05 — Zero-Trust Security Architecture (`mTLS`, `SPIFFE`, `JWT` & `AuthorizationPolicy`)

> **Phase 2: Traffic Engineering, Security & Resilience** | **Cohort 01**
> **Authoritative Baseline**: Istio `1.32.0` | Envoy `v1.40` | Kubernetes `1.36` / `1.37` | Gateway API `v1.6.1`
> **Core Module Mapping**: [Module 04 — Security, mTLS & Authorization (`README.md`)](../../04-security-mtls-and-authz/README.md) & [Guided Lab (`LAB.md`)](../../04-security-mtls-and-authz/LAB.md)

> [!NOTE]
> ### Where You Are & What You Need Before Starting
> - **Current Phase**: Phase 2 — Traffic Engineering, Security & Resilience (Week 05 of 10)
> - **Prerequisites**: Completed Weeks 01–04 (Dedicated `ServiceAccount` SPIFFE identities across `orderflow` and North-South gateway setup)
> - **Estimated Time**: ~6–8 hours
> - **Tangible Weekly Deliverable**: `STRICT` `PeerAuthentication`, default-deny `AuthorizationPolicy` (`allow-nothing`), explicit SPIFFE call-graph policies (`frontend-sa -> order-sa -> payment-sa / inventory-sa`), and OIDC JWT `RequestAuthentication` + `DENY` enforcement (`NP-105`)

---

## Week Metadata & Learning Objectives

| Attribute | Specification |
| :--- | :--- |
| **Fellowship Role** | Platform Engineer — Service Mesh & Cloud-Native Networking Team |
| **Business Context** | Our external PCI-DSS Level 1 Qualified Security Assessor (QSA) arrives next month. Maya Patel requires zero plaintext traffic anywhere inside `orderflow` (`PeerAuthentication: STRICT`), a default-deny `AuthorizationPolicy` baseline with explicit least-privilege SPIFFE rules per call edge, and OIDC/JWT validation (`RequestAuthentication`) including Istio `1.32.0`'s route-targeted `AuthorizationPolicy` on Gateway API `HTTPRoute`. |
| **Primary Namespace** | `orderflow` & `istio-system` |
| **Engineering Ticket** | `NP-105`: Enforce `STRICT` mTLS, Default-Deny SPIFFE RBAC, and JWT + `HTTPRoute`-Scoped Authorization |
| **Incident Simulation** | `INC-05`: Critical Authorization Bypass (`OR` vs. `AND` YAML Indentation Bug Exposing `payment-service`) |

### Learning Objectives
By the end of Week 05, you will be able to:
1. Trace Istio's X.509 PKI lifecycle (`pilot-agent` in-memory private key generation -> gRPC CSR -> `istiod` Citadel CA -> SDS Unix Domain Socket -> Envoy TLS filter chain) and safely transition a namespace from `PERMISSIVE` to `STRICT` mTLS via `PeerAuthentication`.
2. Design a zero-trust, default-deny L7 `AuthorizationPolicy` posture (`spec: {}`) and unlock only the exact service-to-service call graph using cryptographic SPIFFE identities (`source.principals`), HTTP methods, and URI paths.
3. Understand and apply Istio's strict `AuthorizationPolicy` evaluation precedence: **`CUSTOM` -> `DENY` -> `ALLOW`**.
4. Configure `RequestAuthentication` to validate JSON Web Tokens (JWTs) against a JWKS endpoint and bind JWT claims (`request.auth.claims[role]`) inside `AuthorizationPolicy` rules—including Istio `1.32.0`'s ability to target a specific Kubernetes Gateway API `HTTPRoute` via `targetRefs`.

### Required Competencies
- Fluency with X.509 SAN URI inspection, Envoy RBAC filter debugging (`rbac: access denied`), and JWT payload decoding.
- Extreme precision with YAML list indentation (`from` / `to` / `when` boolean `AND` vs. `OR` semantics in `AuthorizationPolicy`).

---

## Monday — Mentor Briefing & Ticket Assignment

### Briefing from Alex Morgan (Senior Platform Engineer)
> *"This week is Maya Patel's favorite week of the fellowship—and the highest-stakes week for any platform engineer working in FinTech. Up until now, `orderflow` has been running in Istio's default `PERMISSIVE` mTLS mode with zero `AuthorizationPolicy` restrictions. That means any pod inside the cluster—even a compromised uninjected pod in a developer sandbox namespace—could send a plaintext HTTP request directly to `payment-service:8080/pay` and execute a fraudulent payout.*
>
> *By Friday afternoon, `orderflow` will be locked down to cryptographic zero trust: `STRICT` mTLS only, a namespace-wide default-deny barrier, explicit SPIFFE `ServiceAccount` allow-lists on every single hop, and JWT claim enforcement. Be very careful with your YAML indentation in `AuthorizationPolicy` this week—one extra hyphen `-` changes a rule from `AND` to `OR` and opens a massive security hole."*

### Peer Engineering Discussion (`#platform-mesh-arch`)

> **Maya Patel (Principal Security Engineer)** `09:00 AM`
> Team, let's review the requirements for `NP-105`. Our PCI-DSS QSA requires proof of three controls in `orderflow`:
> 1. **Cryptographic Transport (`PeerAuthentication`)**: `STRICT` mTLS across `orderflow`. If a rogue pod without a valid Istio SPIFFE certificate connects to any port in `orderflow`, the TCP/TLS handshake must be rejected immediately.
> 2. **Least-Privilege Micro-Segmentation (`AuthorizationPolicy`)**: Default-deny (`allow-nothing`) across `orderflow`. Then we explicitly open only the legitimate call graph:
>    - `istio-ingressgateway` (or `client-toolbox`) -> `frontend`
>    - `frontend` (`frontend-sa`) -> `order-service` (`order-sa`)
>    - `order-service` (`order-sa`) -> `payment-service` (`payment-sa`) and `inventory-service` (`inventory-sa`)
>    Notice what is **forbidden**: `frontend` or `inventory-service` must **never** be allowed to call `payment-service` directly!
> 3. **End-User Identity (`RequestAuthentication` + JWT Claims)**: Calls to `/api/v1/orders` must carry a valid signed JWT, and administrative endpoints (`/admin/*`) must be blocked by an explicit `DENY` policy unless the JWT carries `role: admin` (or `pci-auditor`).

> **Daniel Brooks (Staff Backend Engineer)** `09:05 AM`
> Quick question, Maya. If we enable `RequestAuthentication` on `frontend` or `order-service` to verify the JWT signature against our OIDC JWKS keys, what happens when a caller sends a request **without** an `Authorization: Bearer <token>` header at all? Does `RequestAuthentication` reject unauthenticated requests with `401 Unauthorized`?

> **Alex Morgan (Senior Platform Engineer)** `09:08 AM`
> Watch out, Daniel—that's the #1 misconception about `RequestAuthentication`!
> - **`RequestAuthentication` ONLY validates a JWT *if* a token is present!** If a request arrives with a forged or expired JWT, `RequestAuthentication` returns `401 Unauthorized`. **However**, if a request arrives with **NO JWT header at all**, `RequestAuthentication` lets it pass right through as an anonymous request!
> - To **require** a valid JWT on every request, you **must** pair `RequestAuthentication` with an `AuthorizationPolicy` that checks `requestPrincipals: ["*"]` (or denies `notRequestPrincipals: ["*"]`).

> **Sarah Chen (SRE Lead)** `09:12 AM`
> Also, check out the new Istio `1.32.0` feature for Gateway API: we can now attach an `AuthorizationPolicy` directly to a specific Kubernetes Gateway API **`HTTPRoute`** using `targetRefs` (`kind: HTTPRoute`) instead of only attaching to whole pods or whole Gateways! Make sure we test that in `NP-105`.

---

### Engineering Ticket: `NP-105`

| Field | Details |
| :--- | :--- |
| **Ticket ID** | `NP-105` |
| **Title** | Implement Zero-Trust Security in `orderflow`: `STRICT` mTLS, SPIFFE Call-Graph RBAC & JWT Enforcement |
| **Reporter** | Maya Patel (Principal Security Engineer) |
| **Assignee** | Platform Engineering Fellow |
| **Priority** | P0 — PCI-DSS Audit Requirement |

#### Business Context
NovaPay must eliminate implicit trust inside the `orderflow` namespace. Even if an attacker compromises a peripheral service (such as `inventory-service` or `frontend`) or deploys an uninjected pod in another namespace (`legacy-uninjected`), they must be cryptographically blocked from communicating with `payment-service` or `order-service`.

#### Technical Requirements
1. **Enforce `STRICT` mTLS**:
   - Apply a `PeerAuthentication` policy in `orderflow` (and/or mesh-wide in `istio-system`) with `mtls.mode: STRICT`.
   - Prove that a pod without a sidecar in an uninjected namespace (`legacy-client` in `legacy-uninjected`) is rejected at the TLS handshake layer when calling `orderflow`.
2. **Enforce Default-Deny & Explicit SPIFFE Call Graph**:
   - Apply an `allow-nothing` (`spec: {}`) `AuthorizationPolicy` in `orderflow`.
   - Create explicit `ALLOW` `AuthorizationPolicy` resources for each `orderflow` service (`frontend`, `order-service`, `payment-service`, `inventory-service`) restricting `from.source.principals` to the exact upstream caller's SPIFFE identity (`frontend-sa`, `order-sa`, `toolbox-sa`) and restricting `to.operation.methods` and `paths`.
3. **JWT Validation & Claim-Based Access Control**:
   - Configure a `RequestAuthentication` policy validating JWT tokens against Istio's test OIDC issuer (`testing@secure.istio.io`).
   - Require a valid JWT (`requestPrincipals: ["*"]`) and test Istio `1.32.0`'s route-scoped `AuthorizationPolicy` (`targetRefs` pointing to `HTTPRoute`).

#### Constraints
- Every `ALLOW` `AuthorizationPolicy` must specify explicit `principals`, `methods`, and `paths`—wildcard `principals: ["*"]` is strictly forbidden on backend services.
- Verify all `from` / `to` / `when` list structures so no accidental `OR` conditions are introduced.

#### Acceptance Criteria & Deliverables
- [ ] Uninjected pods in `legacy-uninjected` fail to connect to `orderflow` services (`Recv failure: Connection reset by peer` / exit code `56`).
- [ ] Full checkout flow (`frontend -> order-service -> payment-service & inventory-service`) succeeds (`200 OK`), while direct calls from `frontend` or `inventory-service` to `payment-service` are rejected with `403 RBAC: access denied`.
- [ ] Requests without a valid JWT are rejected with `403`, forged JWTs are rejected with `401`, and valid JWTs with authorized claims succeed (`200 OK`).

---

## Tuesday — Technical Lectures & Architecture Deep-Dive

### Assigned Core Reading & Modular Lessons
Study the complete architectural overview and progressive lessons in Module 04:
- **Core Module Overview**: [**Module 04 — Zero-Trust Security, mTLS, SPIFFE & Authorization (`README.md`)**](../../04-security-mtls-and-authz/README.md)
- **Modular Deep-Dive Lessons**:
  1. [Lesson 04.1: SPIFFE Cryptographic Identity & SDS Certificate Lifecycle](../../04-security-mtls-and-authz/lessons/01-spiffe-identity-and-sds-lifecycle.md)
  2. [Lesson 04.2: Mutual TLS (`PeerAuthentication`) & Zero-Downtime Migration](../../04-security-mtls-and-authz/lessons/02-peer-authentication-and-mtls-migration.md)
  3. [Lesson 04.3: End-User JWT (`RequestAuthentication`) & `AuthorizationPolicy`](../../04-security-mtls-and-authz/lessons/03-jwt-authn-and-authorization-policy.md)

### Alex's Guided Study Notes: What to Pay Attention to Under the Hood
1. **`AuthorizationPolicy` Evaluation Order (`CUSTOM` -> `DENY` -> `ALLOW`)**:
   Envoy's RBAC filter evaluates policies in a strict, deterministic sequence:
   - **Step 1 (`CUSTOM`)**: External authorization (`ext_authz` / OPA / OAuth2-Proxy) runs first. If it denies, the request stops immediately (`403`).
   - **Step 2 (`DENY`)**: All `action: DENY` policies are evaluated next. If **any** `DENY` rule matches, the request is immediately rejected (`403`). A `DENY` rule **always overrides** an `ALLOW` rule!
   - **Step 3 (`ALLOW`)**:
     - If **zero** `ALLOW` policies exist for the workload, the request is **ALLOWED** by default!
     - As soon as **one or more** `ALLOW` policies exist for the workload (including an empty `spec: {}` default-deny policy), the workload switches to **default-deny**: a request is allowed **if and only if** it matches at least one `ALLOW` rule!
2. **Why `spec: {}` Means "Deny Everything"**:
   An `AuthorizationPolicy` with `spec: {}` has the default `action: ALLOW`, matches all workloads in the namespace, and has **no `rules:`**. Because an `ALLOW` policy now exists on every workload in the namespace, Envoy requires a request to match at least one `ALLOW` rule—and since `spec: {}` has zero rules, nothing matches it unless another `ALLOW` policy explicitly permits the traffic!
3. **The Deadly YAML Hyphen (`AND` vs. `OR` in `AuthorizationPolicy`)**:
   Look at the difference a single hyphen `-` makes:
   ```yaml
   # CORRECT (AND logic): Caller must be order-sa AND method must be POST
   rules:
     - from:
         - source:
             principals: ["cluster.local/ns/orderflow/sa/order-sa"]
       to:
         - operation:
             methods: ["POST"]
   ```
   vs.
   ```yaml
   # BROKEN (OR logic!): Caller is order-sa (ANY method!) OR ANY caller using POST!
   rules:
     - from:
         - source:
             principals: ["cluster.local/ns/orderflow/sa/order-sa"]
     - to:
         - operation:
             methods: ["POST"]
   ```

### Zero-Trust Evaluation Flowchart in Envoy (`:15006` Inbound Filter Chain)

```mermaid
flowchart TD
    Req["Inbound Connection to :15006"] --> PA{"1. PeerAuthentication\n(mTLS Mode == STRICT?)"}
    PA -->|Plaintext or Invalid Cert| DropTLS["TLS Handshake Rejected\n(Connection Reset)"]
    PA -->|Valid SPIFFE X.509 SVID| ExtractSAN["Extract Peer SPIFFE ID\n(cluster.local/ns/.../sa/...)"]
    ExtractSAN --> RA{"2. RequestAuthentication\n(JWT Header Present?)"}
    RA -->|Token Present & Invalid/Expired| Reject401["HTTP 401 Unauthorized\n(Jwt verification fails)"]
    RA -->|Valid JWT or No Token| CustomCheck{"3. AuthzPolicy: CUSTOM\n(Matches & Denies?)"}
    CustomCheck -->|Denied| Reject403["HTTP 403 Forbidden\n(RBAC: access denied)"]
    CustomCheck -->|Pass| DenyCheck{"4. AuthzPolicy: DENY\n(Matches ANY Deny Rule?)"}
    DenyCheck -->|Matches a DENY Rule| Reject403
    DenyCheck -->|No DENY Match| AllowExist{"5. AuthzPolicy: ALLOW\n(Do ANY Allow Policies Exist?)"}
    AllowExist -->|No ALLOW Policies Exist| App["200 OK -> Forward to App"]
    AllowExist -->|Yes (e.g. allow-nothing exists)| AllowMatch{"Matches >= 1 ALLOW Rule?"}
    AllowMatch -->|Yes| App
    AllowMatch -->|No| Reject403
```

---

## Wednesday — Guided Labs & Internal Verification

### Step 1: Pre-Flight Check
Verify all `orderflow` workloads are running `2/2 READY` and communicating cleanly:

```bash
kubectl get pods -n orderflow
istioctl proxy-status
```

### Step 2: Execute the Core Module Guided Lab
Complete all exercises in [**Module 04 — Hands-On Lab (`LAB.md`)**](../../04-security-mtls-and-authz/LAB.md):
1. Inspect active X.509 certificates and trust bundles via `istioctl proxy-config secret`.
2. Transition `orderflow` from `PERMISSIVE` to `STRICT` mTLS and test from the uninjected `legacy-client` pod in `legacy-uninjected`.
3. Apply the `allow-nothing` default-deny policy and progressively unlock the `orderflow` SPIFFE call graph.
4. Configure `RequestAuthentication` + JWT claim-based `AuthorizationPolicy` (including `DENY` overrides and Istio `1.32.0` `HTTPRoute` `targetRefs`).

### Step 3: Alex's Internal Verification Checkpoints
Run these internal Envoy filter inspections before moving to Thursday's assignment:

```bash
# Checkpoint 1: Verify STRICT mTLS is programmed on payment-service's inbound listener (transport_socket: envoy.transport_sockets.tls)
PAYMENT_POD=$(kubectl get pod -n orderflow -l app=payment-service,version=v1 -o jsonpath='{.items[0].metadata.name}')
istioctl proxy-config listener "$PAYMENT_POD.orderflow" --port 15006 -o json | grep -B 2 -A 5 "requireClientCertificate"

# Checkpoint 2: Inspect the compiled Envoy HTTP RBAC filter rules on payment-service
istioctl proxy-config listener "$PAYMENT_POD.orderflow" --port 15006 -o json | \
  jq '.. | .["envoy.filters.http.rbac"]? | select(. != null)'
```

---

## Thursday — Independent Engineering Assignment

### Scenario: Defense-in-Depth PCI-DSS Audit Protection on `payment-service` and `order-service`
Maya Patel has handed you the final PCI-DSS security controls specification for `orderflow`:

1. **Cryptographic Baseline**:
   - Enforce `PeerAuthentication` `STRICT` across the entire `orderflow` namespace.
   - Enforce an `allow-nothing` default-deny `AuthorizationPolicy` across `orderflow`.
2. **Service-to-Service SPIFFE Call Graph (`ALLOW` Rules)**:
   - `frontend`: Allow `GET` and `POST` on `/*` and `/healthz` from `toolbox-sa` (for internal synthetic monitoring) and `istio-ingressgateway-service-account` (in `istio-system`).
   - `order-service`: Allow `GET` and `POST` on `/*`, `/api/v1/orders*`, and `/admin/*` **only** from `cluster.local/ns/orderflow/sa/frontend-sa` (and `toolbox-sa` for direct functional testing).
   - `payment-service` and `inventory-service`: Allow `POST` and `GET` **only** from `cluster.local/ns/orderflow/sa/order-sa`.
3. **JWT Authentication & Defense-in-Depth `DENY` Policy on `order-service`**:
   - Attach a `RequestAuthentication` resource `order-jwt-authn` to `order-service` validating tokens issued by `testing@secure.istio.io` (`jwksUri: https://raw.githubusercontent.com/istio/istio/release-1.32/security/tools/jwt/samples/jwks.json`) and setting `forwardOriginalToken: true`.
   - Attach an explicit **`action: DENY`** `AuthorizationPolicy` named `deny-order-admin-without-auditor-claim` to `order-service` that blocks any request to path prefix `/admin`:
     - **Condition 1**: If the request has **no** valid JWT (`notRequestPrincipals: ["*"]`), **OR**
     - **Condition 2**: If the JWT's `role` claim (`request.auth.claims[role]`) is **not** `pci-auditor` (`notValues: ["pci-auditor"]`).

<details>
<summary>Need a Hint from Alex Morgan? (Click before revealing the full answer)</summary>

> **Alex's Coaching Hints**:
> 1. **Exact SPIFFE ServiceAccount Names in `orderflow`**: Remember that in `00-environment-setup/manifests/base-platform.yaml`, the ServiceAccounts in `orderflow` are `frontend-sa`, `order-sa`, `payment-sa`, `inventory-sa`, and `toolbox-sa`!
> 2. **Structuring the Two-Rule `DENY` Policy**: Why do you need **two** separate rules (`- from: ... to: ...` and `- to: ... when: ...`) inside `deny-order-admin-without-auditor-claim`? Because if a request arrives with **no JWT at all**, `request.auth.claims[role]` doesn't exist to be evaluated! Rule 1 (`notRequestPrincipals: ["*"]` on `/admin/*`) blocks unauthenticated requests, and Rule 2 (`when: [{ key: "request.auth.claims[role]", notValues: ["pci-auditor"] }]` on `/admin/*`) blocks authenticated requests that lack the `pci-auditor` role.
> 3. **Evaluation Order**: Because `DENY` always runs before `ALLOW`, your `DENY` policy on `/admin/*` will automatically override `allow-order-service` unless the caller carries a valid `pci-auditor` JWT!

</details>

<details>
<summary>Click to Reveal Reference Solution & Alex's Code Review</summary>

### Reference Solution Manifest (`np-105-zero-trust-solution.yaml`)

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: orderflow-strict-mtls
  namespace: orderflow
spec:
  mtls:
    mode: STRICT
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-nothing
  namespace: orderflow
spec: {}
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-frontend
  namespace: orderflow
spec:
  selector:
    matchLabels:
      app: frontend
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - "cluster.local/ns/orderflow/sa/toolbox-sa"
              - "cluster.local/ns/istio-system/sa/istio-ingressgateway-service-account"
      to:
        - operation:
            methods: ["GET", "POST"]
            paths: ["/*", "/healthz"]
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-order-service
  namespace: orderflow
spec:
  selector:
    matchLabels:
      app: order-service
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - "cluster.local/ns/orderflow/sa/frontend-sa"
              - "cluster.local/ns/orderflow/sa/toolbox-sa"
      to:
        - operation:
            methods: ["GET", "POST"]
            paths: ["/*", "/api/v1/orders*", "/admin/*"]
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-downstream-backends
  namespace: orderflow
spec:
  selector:
    matchLabels:
      app: payment-service
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - "cluster.local/ns/orderflow/sa/order-sa"
      to:
        - operation:
            methods: ["GET", "POST"]
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-inventory-service
  namespace: orderflow
spec:
  selector:
    matchLabels:
      app: inventory-service
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - "cluster.local/ns/orderflow/sa/order-sa"
      to:
        - operation:
            methods: ["GET", "POST"]
---
apiVersion: security.istio.io/v1
kind: RequestAuthentication
metadata:
  name: order-jwt-authn
  namespace: orderflow
spec:
  selector:
    matchLabels:
      app: order-service
  jwtRules:
    - issuer: "testing@secure.istio.io"
      jwksUri: "https://raw.githubusercontent.com/istio/istio/release-1.32/security/tools/jwt/samples/jwks.json"
      forwardOriginalToken: true
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-order-admin-without-auditor-claim
  namespace: orderflow
spec:
  selector:
    matchLabels:
      app: order-service
  action: DENY
  rules:
    - from:
        - source:
            notRequestPrincipals: ["*"]
      to:
        - operation:
            paths: ["/admin/*"]
    - to:
        - operation:
            paths: ["/admin/*"]
      when:
        - key: request.auth.claims[role]
          notValues: ["pci-auditor"]
```

### Verification Commands

```bash
# 1. Apply the Zero-Trust Policy Suite
kubectl apply -f np-105-zero-trust-solution.yaml

# 2. Verify lateral movement is blocked: client-toolbox calling payment-service directly MUST return 403!
TOOLBOX_POD=$(kubectl get pod -n orderflow -l app=client-toolbox -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n orderflow "$TOOLBOX_POD" -c toolbox -- \
  curl -s -o /dev/null -w "%{http_code}\n" http://payment-service.orderflow.svc.cluster.local:8080/pay
# Expected output: 403

# 3. Verify normal call from client-toolbox -> order-service on /api/v1/orders succeeds (200 OK)
kubectl exec -n orderflow "$TOOLBOX_POD" -c toolbox -- \
  curl -s -o /dev/null -w "%{http_code}\n" http://order-service.orderflow.svc.cluster.local:8080/api/v1/orders
# Expected output: 200

# 4. Verify calling /admin/audit on order-service WITHOUT a JWT is blocked by the DENY rule (403 Forbidden)
kubectl exec -n orderflow "$TOOLBOX_POD" -c toolbox -- \
  curl -s -o /dev/null -w "%{http_code}\n" http://order-service.orderflow.svc.cluster.local:8080/admin/audit
# Expected output: 403
```

### Alex's Code Review
> *"Look closely at `deny-order-admin-without-auditor-claim`: why did we include TWO rules in that `DENY` policy?*
> - *Rule 1 (`notRequestPrincipals: ["*"]` on `/admin/*`) catches requests that have **no JWT at all**.*
> - *Rule 2 (`when: request.auth.claims[role] notValues: ["pci-auditor"]` on `/admin/*`) catches requests that **do** have a valid JWT, but where the `role` claim is either missing or set to something other than `pci-auditor`.*
> *And because `DENY` policies are evaluated **before** `ALLOW` policies (`CUSTOM -> DENY -> ALLOW`), even though `allow-order-service` permits `frontend-sa` and `toolbox-sa` to call `/admin/*`, the `DENY` policy intercepts and blocks the call unless a valid `pci-auditor` JWT is present!"*

</details>

---

## Friday — Incident Simulation (`INC-05`)

### PagerDuty Alert: `INC-05` — Critical PCI Compliance Breach (`payment-service` Wide Open to All Callers!)

> **CRITICAL SECURITY INCIDENT — `#inc-05-payment-authz-bypass`**
> **Incident Commander**: Maya Patel (Principal Security Engineer) & Sarah Chen (SRE Lead)
> **Symptom**: Maya's automated continuous compliance scanner (`pci-canary-probe`, running inside `client-toolbox`) periodically attempts to call `http://payment-service.orderflow.svc.cluster.local:8080/pay` to verify that unauthorized pods receive `403 Forbidden`.
>
> Five minutes ago, after an engineer updated `allow-downstream-backends` (`AuthorizationPolicy` on `payment-service`), **the compliance probe returned `HTTP 200 OK`!** `inventory-service`, `frontend`, and `client-toolbox` can all suddenly call `POST /pay` on `payment-service` directly!

### Step 1: Inject the Broken State
Run the following command to apply the engineer's flawed `AuthorizationPolicy` on `payment-service`:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-downstream-backends
  namespace: orderflow
spec:
  selector:
    matchLabels:
      app: payment-service
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - "cluster.local/ns/orderflow/sa/order-sa"
    - to:
        - operation:
            methods: ["POST", "GET"]
            paths: ["/pay*", "/healthz"]
    - when:
        - key: connection.sni
          values: ["outbound_.8080_._.payment-service.orderflow.svc.cluster.local"]
EOF
```

Reproduce the security breach by calling `payment-service` directly from `client-toolbox` (which should be strictly forbidden!):

```bash
TOOLBOX_POD=$(kubectl get pod -n orderflow -l app=client-toolbox -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n orderflow "$TOOLBOX_POD" -c toolbox -- \
  curl -i http://payment-service.orderflow.svc.cluster.local:8080/pay
```

Notice it returns **`HTTP/1.1 200 OK`**!

### Step 2: Diagnostic Clues & Investigation Prompts
1. Inspect the YAML of `allow-downstream-backends` above. How many list items (hyphens `-`) exist directly under `spec.rules:`?
2. Run `istioctl proxy-config listener <payment-pod>.orderflow --port 15006 -o json | jq '.. | .["envoy.filters.http.rbac"]? | select(. != null)'` and examine how Envoy compiled the `policies` map inside the HTTP RBAC filter!
3. Why did `client-toolbox` match this policy even though its SPIFFE ID is `cluster.local/ns/orderflow/sa/toolbox-sa`?

<details>
<summary>Need a Hint from Alex Morgan? (Click before revealing the full answer)</summary>

> **Alex's Diagnostic Hints**:
> 1. Count the hyphens (`-`) directly under `spec.rules:` in `allow-downstream-backends`! There are **three** hyphens (`- from:`, `- to:`, `- when:`).
> 2. In Istio's `AuthorizationPolicy` schema, each hyphen under `rules:` defines a **separate rule** combined with **`OR`** logic! What does a rule with `- to: { operation: { methods: ["POST", "GET"], paths: ["/pay*", "/healthz"] } }` and **no `from:` field** allow? It allows **every principal in the cluster** to call `/pay*`!

</details>

<details>
<summary>Click to Reveal Root Cause Analysis (RCA), Remediation & Postmortem</summary>

### Root Cause Analysis (5-Whys)
1. **Why was `client-toolbox` allowed to call `GET /pay` on `payment-service`?**
   Because Envoy's HTTP RBAC filter matched the request against `rules[1]` (the second rule in `spec.rules`) of `allow-downstream-backends`.
2. **Why did `rules[1]` allow `client-toolbox` without checking `source.principals`?**
   Look at the YAML indentation under `spec.rules:`:
   ```yaml
   rules:
     - from: ...
     - to: ...
     - when: ...
   ```
   The engineer placed a leading hyphen `-` before `from:`, a **second** leading hyphen `-` before `to:`, and a **third** leading hyphen `-` before `when:`!
3. **What does a leading hyphen under `rules:` mean in Istio's `AuthorizationPolicy` schema?**
   Each item in the `rules:` list is an **independent `Rule` object** evaluated with boolean **`OR`** logic!
   - **Rule 0 (`- from:`)** had a `from` block and NO `to` block -> *"Allow `order-sa` to call ANY method and ANY path."*
   - **Rule 1 (`- to:`)** had a `to` block and **NO `from` block** -> *"Allow **ANY caller in the entire universe** to call `POST`/`GET` on `/pay*` or `/healthz`!"*
   - **Rule 2 (`- when:`)** had a `when` block and **NO `from` or `to` block** -> *"Allow **ANY caller** on **ANY path** as long as the mTLS SNI matches `payment-service`!"*
4. **How do we combine `from`, `to`, and `when` with boolean `AND` logic?**
   They must be sibling keys inside a **single** list item under `rules:` (only **one** hyphen `-` before `from:`!).

### Remediation Commands

```bash
# Fix the indentation so from, to, and when are inside the SAME rule object (AND logic)
cat <<'EOF' | kubectl apply -f -
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-downstream-backends
  namespace: orderflow
spec:
  selector:
    matchLabels:
      app: payment-service
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - "cluster.local/ns/orderflow/sa/order-sa"
      to:
        - operation:
            methods: ["POST", "GET"]
            paths: ["/pay*", "/healthz", "/*"]
      when:
        - key: connection.sni
          values: ["outbound_.8080_._.payment-service.orderflow.svc.cluster.local"]
EOF

# Verify client-toolbox is immediately blocked with 403 RBAC: access denied!
TOOLBOX_POD=$(kubectl get pod -n orderflow -l app=client-toolbox -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n orderflow "$TOOLBOX_POD" -c toolbox -- \
  curl -i http://payment-service.orderflow.svc.cluster.local:8080/pay

# Verify end-to-end checkout via order-service is still allowed (200 OK)
kubectl exec -n orderflow "$TOOLBOX_POD" -c toolbox -- \
  curl -i http://order-service.orderflow.svc.cluster.local:8080/

# Clean up Week 05 policies when finished so the cluster is ready for Week 06
kubectl delete -f np-105-zero-trust-solution.yaml --ignore-not-found
```

</details>

---

## Saturday — Architecture Review & Mentor Office Hours

### Architecture Defense Questions
1. **Alex Morgan (Platform)**: *"Suppose a service in `orderflow` has a Kubernetes `livenessProbe` and `readinessProbe` configured via `httpGet` on `/healthz` port `8080`. When we turn on `PeerAuthentication: STRICT` in `orderflow`, `kubelet` on the host node is NOT part of the service mesh and does NOT have an Istio mTLS client certificate! Why don't our pods fail their readiness probes and enter a `CrashLoopBackOff`?"*
2. **Sarah Chen (SRE)**: *"If our external OIDC provider's JWKS endpoint (`jwksUri`) goes down for 10 minutes during a network outage, what happens to `RequestAuthentication` on `order-service`? How does `istiod` fetch JWKS keys?"*
3. **Daniel Brooks (Backend)**: *"In our application code inside `order-service`, once Envoy validates the JWT via `RequestAuthentication`, how can my Go service read the validated JWT claims without re-fetching the JWKS key and re-verifying the cryptographic signature in Go?"*
4. **Maya Patel (Security)**: *"In Istio `1.32.0`, what is the difference between `source.principals` and `source.requestPrincipals` in an `AuthorizationPolicy`? What happens if we use `source.principals` when `PeerAuthentication` is `PERMISSIVE` and a caller connects over plaintext?"*

### Alex's Office Hours Q&A (Deep-Dive Edge Cases)

**Q1: How Istio Probe Rewriting Saves `kubelet` Health Checks Under `STRICT` mTLS**
> **Alex's Answer**: By default (`meshConfig.enableAutoMtls: true` and `values.sidecarInjectorWebhook.rewriteAppHTTPProbe: true`), when the `istio-sidecar-injector` mutating webhook injects `istio-proxy` into a `Pod`, it **rewrites** the `Pod`'s `livenessProbe` and `readinessProbe` `httpGet` port to `15020` (`/app-health/<container-name>/livez` on `pilot-agent`)!
> `kubelet` sends its plaintext HTTP probe to `pilot-agent` on `:15020` (which is excluded from `iptables` `:15006` mTLS interception), and `pilot-agent` inside the pod makes a local loopback request to the application container on `8080`, completely avoiding the `STRICT` mTLS filter chain on `:15006`! (Note: For `tcpSocket` probes, ensure they are converted to `httpGet` or `exec`, or exempt the probe port if needed).

**Q2: JWKS Fetching & `outputPayloadToHeader`**
> **Alex's Answer**: `istiod` fetches the `jwksUri` (or you can inline `jwks` directly in `RequestAuthentication` for air-gapped resilience!) and pushes the public keys to Envoy over RDS/LDS filter config. If `jwksUri` becomes unreachable when `istiod` restarts or rotates keys, new `RequestAuthentication` reconciliations can fail unless cached or inlined. For mission-critical PCI workloads, we either point `jwksUri` to an internal in-cluster OIDC service or populate the `jwks:` inline string directly via GitOps!

**Q3: Passing Verified Claims to the Application (`outputPayloadToHeader`)**
> **Alex's Answer**: In `RequestAuthentication.spec.jwtRules[]`, set **`outputPayloadToHeader: x-jwt-payload`**. Once Envoy verifies the JWT's cryptographic signature and expiration, Envoy strips any spoofed incoming `x-jwt-payload` header from the client and injects the base64-decoded JSON payload of the verified token into `x-jwt-payload`! Because `order-service` is protected by `STRICT` mTLS, the Go app can safely parse `x-jwt-payload` without doing RSA/ECDSA signature math again.

**Q4: `source.principals` vs. `source.requestPrincipals`**
> **Alex's Answer**:
> - **`source.principals`** is the **workload identity** extracted from the peer's **X.509 mTLS certificate SAN** (`cluster.local/ns/orderflow/sa/order-sa`). It requires **mTLS**! If `PeerAuthentication` is `PERMISSIVE` and a caller connects in plaintext, `source.principals` is empty (`""`) and will fail to match any `source.principals` rule.
> - **`source.requestPrincipals`** is the **end-user identity** extracted from the **JWT token** (`<iss>/<sub>`, e.g., `testing@secure.istio.io/testing@secure.istio.io`).

---

## Sunday — Weekly Assessment & Reflection

### Competency Assessment

1. **PKI & SDS Architecture**:
   Trace the step-by-step creation and rotation of a workload's X.509 certificate in Istio `1.32.0`. Which binary generates the private key, what protocol sends the CSR to `istiod`, and what local mechanism delivers the signed certificate to Envoy?

2. **Policy Precedence Puzzle**:
   Workload `payment-service` has three `AuthorizationPolicy` objects applied to it:
   - Policy A (`action: ALLOW`): Allows `order-service-sa` on `POST /pay`.
   - Policy B (`action: DENY`): Denies any request where header `x-fraud-risk` is `high`.
   - Policy C (`allow-nothing`, `spec: {}`).
   Determine the HTTP status code (`200` or `403`) for each of the following requests:
   - *(a)* `order-service-sa` sends `POST /pay` with header `x-fraud-risk: low`.
   - *(b)* `order-service-sa` sends `POST /pay` with header `x-fraud-risk: high`.
   - *(c)* `order-service-sa` sends `GET /pay` with header `x-fraud-risk: low`.

3. **Port-Level `PeerAuthentication` Overrides**:
   Suppose `orderflow` has a namespace-wide `PeerAuthentication` with `mtls.mode: STRICT`. However, `legacy-metrics-scraper` (an uninjected pod) must scrape port `9091` on `payment-service` in plaintext, while port `8080` on `payment-service` remains `STRICT`. Write the exact `PeerAuthentication` spec for `payment-service` to achieve this.

4. **`RequestAuthentication` Behavior Matrix**:
   A workload has a `RequestAuthentication` policy configured, and **zero** `AuthorizationPolicy` resources exist in the namespace. What HTTP response code (`200`, `401`, or `403`) does Envoy return for:
   - *(a)* Request with a valid JWT.
   - *(b)* Request with a corrupted/expired JWT.
   - *(c)* Request with **no** `Authorization` header at all.

5. **Istio `1.32.0` Gateway API `HTTPRoute` Authorization**:
   How does targeting an `AuthorizationPolicy` at `targetRefs: [{ group: gateway.networking.k8s.io, kind: HTTPRoute, name: orders-route }]` differ from attaching an `AuthorizationPolicy` via `selector.matchLabels` to the Gateway pod?

<details>
<summary>Assessment Answer Key</summary>

1. **PKI & SDS Architecture**:
   - `pilot-agent` inside `istio-proxy` generates the private key in memory (never written to disk/etcd), creates an X.509 CSR, and sends it over an authenticated gRPC stream (presenting the projected Kubernetes `ServiceAccount` token) to `istiod`'s CA. `istiod` validates the token via Kubernetes `TokenReview`, signs the certificate with the `spiffe://cluster.local/ns/<ns>/sa/<sa>` SAN, and returns it to `pilot-agent`, which pushes the key and certificate to Envoy over a local Unix Domain Socket using the **Secret Discovery Service (SDS)** API.

2. **Policy Precedence Puzzle**:
   - *(a)* **`200 OK`**: Does not match Policy B (`DENY`), and matches Policy A (`ALLOW`).
   - *(b)* **`403 Forbidden`**: Matches Policy B (`DENY`). `DENY` is evaluated before `ALLOW` and always wins!
   - *(c)* **`403 Forbidden`**: Does not match Policy B (`DENY`), and fails to match Policy A (`ALLOW`) because method is `GET` instead of `POST`. Since `ALLOW` policies exist on the workload, unmatched requests are denied by default.

3. **Port-Level `PeerAuthentication` Overrides**:
   > **Note**: In `PeerAuthentication.spec.portLevelMtls`, you must specify the **container (`targetPort`) port number**, not the Kubernetes `Service` port number!
   ```yaml
   apiVersion: security.istio.io/v1
   kind: PeerAuthentication
   metadata:
     name: payment-metrics-override
     namespace: orderflow
   spec:
     selector:
       matchLabels:
         app: payment-service
     mtls:
       mode: STRICT
     portLevelMtls:
       9091:
         mode: PERMISSIVE # or DISABLE
   ```

4. **`RequestAuthentication` Behavior Matrix**:
   - *(a)* `200 OK`
   - *(b)* `401 Unauthorized`
   - *(c)* **`200 OK`** (`RequestAuthentication` allows requests with no token unless paired with an `AuthorizationPolicy` requiring `requestPrincipals: ["*"]`!)

5. **Istio `1.32.0` Gateway API `HTTPRoute` Authorization**:
   - Attaching an `AuthorizationPolicy` to the Gateway pod (`selector` or `targetRefs: Gateway`) applies the RBAC policy to **every route and hostname** hosted on that Gateway listener. Targeting `kind: HTTPRoute` in Istio `1.32.0` compiles the RBAC rule as an **per-route filter (`typed_per_filter_config`)** inside Envoy's `RouteConfiguration` (`RDS`), so the policy applies strictly to traffic matching that single `HTTPRoute` without affecting other teams sharing the same Gateway!

</details>

---

### Weekly Competency Sign-Off Checklist
- [ ] Enforced `PeerAuthentication: STRICT` across `orderflow` and verified plaintext rejection.
- [ ] Deployed `allow-nothing` default-deny and unlocked the exact `orderflow` SPIFFE call graph.
- [ ] Configured `RequestAuthentication` + JWT claim-based `DENY` and `ALLOW` rules in Thursday's assignment.
- [ ] Diagnosed and remediated the `OR` vs. `AND` YAML indentation vulnerability in Friday's `INC-05` security incident.
- [ ] Ready to advance to **Week 06 (Resilience Engineering, Fault Injection & Circuit Breaking)**.
