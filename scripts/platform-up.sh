#!/usr/bin/env bash
# =============================================================================
# Bring up the cage (platform plane): namespaces, resource governance, tenant
# RBAC, default-deny egress NetworkPolicy, and the TLS-intercepting egress proxy
# with a generated CA. Idempotent.
#
# Requires: kubectl (override with KUBECTL=), openssl, yq.
# =============================================================================
set -euo pipefail
KUBECTL="${KUBECTL:-kubectl}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CADIR="${CADIR:-$ROOT/.cage-ca}"   # holds the proxy CA private key — gitignored

echo "==> namespaces, quotas, RBAC, network policy, admission policy"
$KUBECTL apply -f "$ROOT/platform/constraints/namespaces.yaml"
$KUBECTL apply -f "$ROOT/platform/constraints/quota.yaml"
$KUBECTL apply -f "$ROOT/platform/rbac/tenant-rbac.yaml"
$KUBECTL apply -f "$ROOT/platform/netpol/egress.yaml"
# Native ValidatingAdmissionPolicy: private-registry-only + no :latest (no controller needed).
$KUBECTL apply -f "$ROOT/platform/policies/admission-policies.yaml"
# In-cluster private registry (the cage's example registry).
$KUBECTL apply -f "$ROOT/platform/registry/registry.yaml"
# Signature enforcement at admission — only if Kyverno is installed.
if $KUBECTL get crd clusterpolicies.kyverno.io >/dev/null 2>&1; then
  $KUBECTL apply -f "$ROOT/platform/policies/kyverno-verify-images.yaml"
  echo "   applied Kyverno verify-images policy"
else
  echo "   (Kyverno not installed — skipping verify-images; native provenance policy still active)"
fi

echo "==> egress proxy CA"
mkdir -p "$CADIR"; chmod 700 "$CADIR"
if [ ! -f "$CADIR/mitmproxy-ca.pem" ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$CADIR/ca.key" -out "$CADIR/ca.crt" \
    -subj "/CN=Halden Egress Proxy CA/O=Halden Pharma" 2>/dev/null
  cat "$CADIR/ca.key" "$CADIR/ca.crt" > "$CADIR/mitmproxy-ca.pem"
  echo "   generated new CA"
fi
# CA (key+cert) for the proxy; cert-only for the tenant to trust.
$KUBECTL -n halden-platform create secret generic mitmproxy-ca \
  --from-file=mitmproxy-ca.pem="$CADIR/mitmproxy-ca.pem" \
  --dry-run=client -o yaml | $KUBECTL apply -f -
$KUBECTL -n cap create configmap halden-proxy-ca \
  --from-file=ca.crt="$CADIR/ca.crt" \
  --dry-run=client -o yaml | $KUBECTL apply -f -

echo "==> proxy addon + allowlist (permanent entries only; empty == air-gap)"
$KUBECTL -n halden-platform create configmap egress-proxy-addon \
  --from-file=allowlist.py="$ROOT/platform/egress-proxy/allowlist.py" \
  --dry-run=client -o yaml | $KUBECTL apply -f -
yq -r '.permanent[]?.fqdn' "$ROOT/allowlist.yaml" > "$CADIR/allowlist.txt" 2>/dev/null || : > "$CADIR/allowlist.txt"
$KUBECTL -n halden-platform create configmap egress-allowlist \
  --from-file=allowlist.txt="$CADIR/allowlist.txt" \
  --dry-run=client -o yaml | $KUBECTL apply -f -

echo "==> deploy egress proxy"
$KUBECTL apply -f "$ROOT/platform/egress-proxy/deployment.yaml"
$KUBECTL -n halden-platform rollout status deploy/egress-proxy --timeout=120s

echo "==> cage is up. proxy allowlist entries: $(grep -cve '^$' "$CADIR/allowlist.txt" || echo 0)"
