#!/usr/bin/env bash
# =============================================================================
# Air-gap assertion: put the egress proxy in FULL DENY (empty allowlist) and
# prove the application still serves. This is the headline signal — the install
# needs zero external egress at runtime.
#
# Exit non-zero if the app is not serving or if egress is NOT actually blocked.
# Requires: kubectl (override with KUBECTL=).
# =============================================================================
set -uo pipefail
KUBECTL="${KUBECTL:-kubectl}"
NS_TENANT="${NS_TENANT:-cap}"
NS_PLATFORM="${NS_PLATFORM:-halden-platform}"
PROXY="egress-proxy.${NS_PLATFORM}:3128"
fail=0

echo "== 1. Force the proxy into full-deny (empty allowlist) =="
$KUBECTL -n "$NS_PLATFORM" create configmap egress-allowlist \
  --from-literal=allowlist.txt="" --dry-run=client -o yaml | $KUBECTL apply -f -
$KUBECTL -n "$NS_PLATFORM" rollout restart deploy/egress-proxy
$KUBECTL -n "$NS_PLATFORM" rollout status deploy/egress-proxy --timeout=90s

echo "== 2. App still serving? (cap-web HTTP status) =="
code=$($KUBECTL -n "$NS_TENANT" exec deploy/cap-web -c web -- \
  sh -c 'wget -T 8 -S -qO /dev/null http://127.0.0.1:3000/ 2>&1 | awk "/HTTP\//{c=\$2} END{print c}"' 2>/dev/null || echo "ERR")
if [ "$code" = "200" ] || [ "$code" = "307" ]; then
  echo "   OK: cap-web returned HTTP $code with the proxy in full deny"
else
  echo "   FAIL: cap-web returned '$code'"; fail=1
fi

echo "== 3. Egress actually blocked? (tenant -> internet via proxy must be denied) =="
out=$($KUBECTL -n "$NS_TENANT" exec deploy/cap-web -c web -- \
  sh -c "http_proxy=http://$PROXY wget -T 8 -qO- http://example.com/ 2>&1" || true)
if echo "$out" | grep -q "403"; then
  echo "   OK: proxy denied egress (403)"
else
  echo "   FAIL: egress was NOT denied: $out"; fail=1
fi

echo "== 4. Direct egress (bypassing proxy) also blocked by NetworkPolicy? =="
if $KUBECTL -n "$NS_TENANT" exec deploy/cap-web -c web -- \
  sh -c 'wget -T 5 -qO- http://1.1.1.1/ 2>&1' >/dev/null 2>&1; then
  echo "   FAIL: direct egress succeeded (netpol not enforcing)"; fail=1
else
  echo "   OK: direct egress blocked by NetworkPolicy"
fi

echo
if [ "$fail" = "0" ]; then
  echo "AIR-GAP ASSERTION PASSED: app serves with the network in full deny."
else
  echo "AIR-GAP ASSERTION FAILED."
fi
exit $fail
