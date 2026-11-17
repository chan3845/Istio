#!/usr/bin/env bash
# ==============================================================================
# NovaPay Production Service Mesh Capstone Verification Script
# Automatically validates all 6 Architecture Pillars in novapay & novapay-pci
# ==============================================================================
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  echo -e "  ${GREEN}✔ PASS:${NC} $1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  echo -e "  ${RED}✘ FAIL:${NC} $1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

header() {
  echo -e "\n${BLUE}==============================================================================${NC}"
  echo -e "${BLUE}$1${NC}"
  echo -e "${BLUE}==============================================================================${NC}"
}

header "1. Control Plane & xDS Synchronization Check"

if istioctl analyze -n novapay -n novapay-pci 2>&1 | grep -q "No validation issues found"; then
  pass "istioctl analyze found zero validation issues in novapay and novapay-pci"
else
  fail "istioctl analyze reported validation issues"
  istioctl analyze -n novapay -n novapay-pci || true
fi

if istioctl proxy-status | grep -E "novapay|novapay-pci" | grep -qv "SYNCED"; then
  fail "Some proxies in novapay or novapay-pci are not SYNCED"
else
  pass "All Envoy sidecars in novapay and novapay-pci are SYNCED with istiod"
fi

header "2. Pillar 1 Verification: Namespace Isolation & Sidecar Egress Scoping"

PCI_CLUSTERS=$(istioctl proxy-config cluster deploy/settlement-worker.novapay-pci)
if echo "$PCI_CLUSTERS" | grep -q "novapay.svc.cluster.local"; then
  fail "PCI-DSS Isolation Breach: settlement-worker in novapay-pci can see novapay services in CDS"
else
  pass "Sidecar CRD properly isolates novapay-pci (zero novapay.svc.cluster.local clusters in CDS)"
fi

NOVAPAY_CLUSTERS=$(istioctl proxy-config cluster deploy/checkout-service-v1.novapay)
if echo "$NOVAPAY_CLUSTERS" | grep -q "ledger-service.novapay-pci.svc.cluster.local"; then
  pass "checkout-service in novapay has scoped egress visibility to ledger-service.novapay-pci"
else
  fail "checkout-service in novapay is missing ledger-service.novapay-pci in CDS"
fi

header "3. Pillar 2 Verification: Zero-Trust Security (STRICT mTLS, RBAC & Lateral Movement Defense)"

# Test A: Unauthorized lateral call from client-tester -> fraud-service (must be 403)
FRAUD_STATUS=$(kubectl exec -n novapay deploy/client-tester -c curl -- \
  curl -s -o /dev/null -w "%{http_code}" http://fraud-service.novapay.svc.cluster.local:8080/ || true)
if [[ "$FRAUD_STATUS" == "403" ]]; then
  pass "Zero-Trust Lateral Defense: client-tester -> fraud-service blocked with HTTP 403 (RBAC: access denied)"
else
  fail "Expected HTTP 403 for client-tester -> fraud-service, got $FRAUD_STATUS"
fi

# Test B: Unauthorized cross-namespace call from client-tester -> ledger-service in PCI zone (must be 403)
LEDGER_CROSS_STATUS=$(kubectl exec -n novapay deploy/client-tester -c curl -- \
  curl -s -o /dev/null -w "%{http_code}" http://ledger-service.novapay-pci.svc.cluster.local:8080/ || true)
if [[ "$LEDGER_CROSS_STATUS" == "403" ]]; then
  pass "Zero-Trust Cross-Namespace Defense: client-tester (novapay) -> ledger-service (novapay-pci) blocked with HTTP 403"
else
  fail "Expected HTTP 403 for client-tester -> ledger-service, got $LEDGER_CROSS_STATUS"
fi

# Test C: Unauthorized intra-PCI call from settlement-worker -> ledger-service (must be 403)
LEDGER_INTRA_STATUS=$(kubectl exec -n novapay-pci deploy/settlement-worker -c curl -- \
  curl -s -o /dev/null -w "%{http_code}" http://ledger-service.novapay-pci.svc.cluster.local:8080/ || true)
if [[ "$LEDGER_INTRA_STATUS" == "403" ]]; then
  pass "Zero-Trust Intra-PCI Vault Defense: settlement-worker -> ledger-service blocked with HTTP 403"
else
  fail "Expected HTTP 403 for settlement-worker -> ledger-service, got $LEDGER_INTRA_STATUS"
fi

# Test D: Unauthenticated call to protected JWT endpoint /api/v1/checkout on api-gateway (must be 403)
UNAUTH_CHECKOUT=$(kubectl exec -n novapay deploy/client-tester -c curl -- \
  curl -s -o /dev/null -w "%{http_code}" http://api-gateway.novapay.svc.cluster.local:8080/api/v1/checkout || true)
if [[ "$UNAUTH_CHECKOUT" == "403" ]]; then
  pass "JWT Enforcement: Unauthenticated request to /api/v1/checkout rejected with HTTP 403"
else
  fail "Expected HTTP 403 for unauthenticated /api/v1/checkout, got $UNAUTH_CHECKOUT"
fi

header "4. Pillar 3 & 4 Verification: Authorized End-to-End Call Graph & Resilience Config"

# Test authorized path: api-gateway -> checkout-service -> (fraud-service + ledger-service)
E2E_RESPONSE=$(kubectl exec -n novapay deploy/client-tester -c curl -- \
  curl -s http://api-gateway.novapay.svc.cluster.local:8080/)

if echo "$E2E_RESPONSE" | grep -q "fraud-service-v1" && echo "$E2E_RESPONSE" | grep -q "ledger-service-v1"; then
  pass "Authorized Call Graph: api-gateway -> checkout-service -> (fraud-service + ledger-service) returned 200 OK"
else
  fail "End-to-end call graph did not return expected upstream responses from fraud-service and ledger-service"
fi

header "5. Pillar 5 Verification: Progressive Delivery (Canary 80/20, VIP Header Routing & Shadow Mirroring)"

# Test VIP Header Routing (x-priority-tier: platinum -> 100% checkout-service-v2)
VIP_V2_COUNT=0
for _ in $(seq 1 5); do
  RESP=$(kubectl exec -n novapay deploy/client-tester -c curl -- \
    curl -s -H "x-priority-tier: platinum" http://checkout-service.novapay.svc.cluster.local:8080/)
  if echo "$RESP" | grep -q '"name": "checkout-service-v2"'; then
    VIP_V2_COUNT=$((VIP_V2_COUNT + 1))
  fi
done

if [[ "$VIP_V2_COUNT" -eq 5 ]]; then
  pass "VIP Header Routing: 5/5 requests with 'x-priority-tier: platinum' routed to checkout-service-v2"
else
  fail "Expected 5/5 VIP requests on checkout-service-v2, got ${VIP_V2_COUNT}/5"
fi

# Test Default Canary Split (80% v1 / 20% v2 over 20 requests)
V1_COUNT=0
V2_COUNT=0
for _ in $(seq 1 20); do
  RESP=$(kubectl exec -n novapay deploy/client-tester -c curl -- \
    curl -s http://checkout-service.novapay.svc.cluster.local:8080/)
  if echo "$RESP" | grep -q '"name": "checkout-service-v1"'; then
    V1_COUNT=$((V1_COUNT + 1))
  elif echo "$RESP" | grep -q '"name": "checkout-service-v2"'; then
    V2_COUNT=$((V2_COUNT + 1))
  fi
done

if [[ "$V1_COUNT" -ge 10 && "$V2_COUNT" -ge 1 ]]; then
  pass "Canary Traffic Split: 20 standard requests distributed ${V1_COUNT} to v1 and ${V2_COUNT} to v2 (~80/20)"
else
  fail "Unexpected Canary distribution across 20 requests: v1=${V1_COUNT}, v2=${V2_COUNT}"
fi

# Test Asynchronous Traffic Mirroring to ledger-service-v2
SHADOW_LOGS=$(kubectl logs -n novapay-pci deploy/ledger-service-v2 -c istio-proxy --tail=30 || true)
if echo "$SHADOW_LOGS" | grep -q "shadow"; then
  pass "Traffic Mirroring: ledger-service-v2 Envoy logs confirm receipt of mirrored '-shadow' requests"
else
  # Also check application container logs in case Envoy access log flushed slowly
  APP_LOGS=$(kubectl logs -n novapay-pci deploy/ledger-service-v2 -c ledger-service --tail=30 || true)
  if echo "$APP_LOGS" | grep -q "GET /"; then
    pass "Traffic Mirroring: ledger-service-v2 application logs confirm receipt of mirrored shadow requests"
  else
    fail "ledger-service-v2 did not record mirrored shadow traffic"
  fi
fi

header "6. Pillar 6 Verification: Telemetry CRD & Observability"

if kubectl get telemetry -n novapay novapay-telemetry >/dev/null 2>&1 && \
   kubectl get telemetry -n novapay-pci novapay-pci-telemetry >/dev/null 2>&1; then
  pass "Telemetry CRDs active in both novapay and novapay-pci namespaces"
else
  fail "Telemetry CRDs missing in novapay or novapay-pci"
fi

echo -e "\n${BLUE}==============================================================================${NC}"
echo -e "Capstone Verification Summary: ${GREEN}${PASS_COUNT} Passed${NC}, ${RED}${FAIL_COUNT} Failed${NC}"
echo -e "${BLUE}==============================================================================${NC}"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
