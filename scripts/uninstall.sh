#!/usr/bin/env bash
# =============================================================================
# Uninstall Cap and prove nothing is left behind. StatefulSet PVCs are NOT
# removed by `helm uninstall`, so we remove them explicitly — but only after a
# backup (data is destroyed). Set SKIP_BACKUP=1 to skip (e.g. throwaway env).
# =============================================================================
set -uo pipefail
KUBECTL="${KUBECTL:-kubectl}"
HELM="${HELM:-helm}"
NS="${NS:-cap}"
RELEASE="${RELEASE:-cap}"

if [ "${SKIP_BACKUP:-0}" != "1" ]; then
  echo "== backing up MySQL before destroying data (set SKIP_BACKUP=1 to skip) =="
  "$(dirname "$0")/backup.sh" || { echo "backup failed — aborting uninstall"; exit 1; }
fi

echo "== helm uninstall =="
$HELM uninstall "$RELEASE" -n "$NS" --wait || true

echo "== removing StatefulSet PVCs (helm leaves these) =="
$KUBECTL delete pvc -n "$NS" -l app.kubernetes.io/instance="$RELEASE" --ignore-not-found
# volumeClaimTemplate PVCs aren't labeled by helm; remove by name pattern too.
$KUBECTL delete pvc -n "$NS" -l app.kubernetes.io/name=cap --ignore-not-found
$KUBECTL get pvc -n "$NS" -o name | grep -E 'data-cap-(mysql|minio)' | xargs -r $KUBECTL delete -n "$NS" || true

echo "== verifying nothing is left in $NS =="
left=$($KUBECTL get all,pvc,secret,configmap -n "$NS" \
  -l app.kubernetes.io/name=cap -o name 2>/dev/null | wc -l)
# also catch the generated secret / leftover pods
extra=$($KUBECTL get pods,pvc -n "$NS" --no-headers 2>/dev/null | grep -c 'cap-' || true)
if [ "$left" -eq 0 ] && [ "$extra" -eq 0 ]; then
  echo "CLEAN: no Cap resources remain in namespace $NS."
else
  echo "RESIDUE FOUND:"; $KUBECTL get all,pvc,secret -n "$NS" | grep cap- || true
  exit 1
fi
