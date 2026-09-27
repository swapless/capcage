#!/usr/bin/env bash
# =============================================================================
# Verification suite — proves the cage bites and the install is healthy.
# Each check prints PASS/FAIL; exits non-zero if any fail.
# =============================================================================
set -uo pipefail
KUBECTL="${KUBECTL:-kubectl}"
NS="${NS:-cap}"
PLAT="${PLAT:-halden-platform}"
fail=0
pass(){ echo "  PASS: $1"; }
bad(){ echo "  FAIL: $1"; fail=1; }

echo "== 1. Cap pods Ready =="
notready=$($KUBECTL get pods -n "$NS" --no-headers 2>/dev/null | awk '{split($2,a,"/"); if(a[1]!=a[2]) print $1}')
[ -z "$notready" ] && pass "all pods ready" || bad "not ready: $notready"

echo "== 2. Namespace-scoped RBAC (no cluster power) =="
if [ "$($KUBECTL auth can-i get nodes --as=system:serviceaccount:$NS:cap-deployer 2>/dev/null)" = "no" ]; then
  pass "deployer cannot get nodes"; else bad "deployer has cluster access"; fi

echo "== 3. Default-deny egress bites (off-namespace blocked) =="
out=$($KUBECTL exec -n "$NS" deploy/cap-web -c web -- node -e '
const t=(h,p)=>new Promise(r=>{const s=require("net").connect(p,h,()=>{console.log("OPEN");s.destroy();r()});s.on("error",()=>{console.log("BLOCKED");r()});setTimeout(()=>{console.log("BLOCKED");s.destroy();r()},4000)});
t("10.96.0.1",443);' 2>/dev/null | head -1)
[ "$out" = "BLOCKED" ] && pass "egress to k8s API blocked by netpol" || bad "egress not blocked ($out)"

echo "== 4. Admission policy denies bad images =="
badimg=$($KUBECTL run vtest -n "$NS" --image=evil.example.com/x:latest --dry-run=server --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"c","image":"evil.example.com/x:latest","securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' 2>&1 || true)
echo "$badimg" | grep -qiE 'denied|forbidden|allowed registry' && pass "off-registry image denied" || bad "off-registry image NOT denied"

echo "== 5. Proxy denial log has real denies =="
$KUBECTL logs -n "$PLAT" deploy/egress-proxy -c mitmproxy 2>/dev/null | grep -q "DENY" \
  && pass "proxy logged denials" || echo "  INFO: no denials yet (generate one with an egress attempt)"

echo "== 6. App serving =="
code=$($KUBECTL exec -n "$NS" deploy/cap-web -c web -- sh -c 'wget -T8 -S -qO /dev/null http://127.0.0.1:3000/ 2>&1 | awk "/HTTP\//{c=\$2} END{print c}"' 2>/dev/null || echo ERR)
{ [ "$code" = "200" ] || [ "$code" = "307" ]; } && pass "cap-web serving (HTTP $code)" || bad "cap-web not serving ($code)"

echo
[ "$fail" = 0 ] && echo "VERIFY: ALL CHECKS PASSED" || echo "VERIFY: FAILURES ABOVE"
exit $fail
