# Runbook — operating Cap in the Halden cage

Written for **your** on-call at 3am, not for us. Every procedure is copy-pasteable.
If a step needs us on a call, it's a bug — file it.

Assumptions: you have `kubectl` + `helm` against the target cluster and can reach your
private registry. Namespace is `cap`. Release is `cap`. Override tool paths on any
command with `KUBECTL=... HELM=...`.

> **This dev host only:** host↔cluster networking is firewalled, so `kubectl`/`helm`
> are run from a container on the kind network via `scratchpad/kt.sh`. On a normal
> machine/GKE, use `kubectl`/`helm` directly. See decisions/README.

---

## 0. Quick reference

| Task | Command |
|---|---|
| Stand up the cage | `make up` |
| Load images offline (air-gap) | `make load-images` |
| Install / upgrade | `make install` |
| Verify | `make verify` |
| Prove the air-gap | `make air-gap` |
| Roll back | `make rollback` |
| Uninstall (leaves nothing) | `make uninstall` |
| Tear down the cage | `make down` |

---

## 1. Install (nothing → working)

Prereq: images mirrored + signed into your registry (see §8) and the chart pointed at it.

```
# point the whole install at your private registry:
helm upgrade --install cap install/helm/cap -n cap --create-namespace \
  -f install/helm/cap/profiles/values-gke.yaml \
  --set global.imageRegistry=<your-registry>/cap \
  --set global.imagePullSecrets='{regcred}' \
  --atomic --wait --timeout 10m
```

`--atomic` means a failed install auto-rolls-back to nothing. Watch:
```
kubectl -n cap get pods -w
kubectl -n cap logs deploy/cap-web -f     # look for "Migrations run successfully!"
```

First login with no email provider: the login code is printed to the web log:
```
kubectl -n cap logs deploy/cap-web | grep -i "login"
```

## 2. Upgrade

Change window is Thursdays; upgrades are rollback-not-fix-forward.
```
helm upgrade cap install/helm/cap -n cap -f <profile> --atomic --wait --timeout 10m
helm -n cap history cap
```
`--atomic` auto-reverts a failed upgrade. Migrations run in-process in cap-web on start;
they are additive (Drizzle). If cap-web crash-loops after an upgrade, go to §3.

## 3. Rollback (including from a HALF-APPLIED state)

The dangerous case: an upgrade died mid-migration and cap-web is crash-looping.

```
helm -n cap history cap                       # find the last good REVISION
helm rollback cap <REVISION> -n cap --wait --timeout 10m
kubectl -n cap rollout status deploy/cap-web
```

If a partially-applied migration left the DB inconsistent (rare — Drizzle migrations are
transactional per file), restore the DB from the most recent backup (§7), then roll the
chart back:
```
# 1) scale web down so nothing writes
kubectl -n cap scale deploy/cap-web --replicas=0
# 2) restore DB (see §7)
# 3) helm rollback to the revision matching that backup
helm rollback cap <REVISION> -n cap --wait
kubectl -n cap scale deploy/cap-web --replicas=1
```
Verify: `make verify`.

## 4. Uninstall (leaves NOTHING)

`helm uninstall` does **not** delete StatefulSet PVCs. `make uninstall` backs up first,
then removes them and asserts the namespace is clean.
```
make uninstall            # backs up MySQL, uninstalls, deletes PVCs, verifies clean
# throwaway env, skip backup:
SKIP_BACKUP=1 make uninstall
```
It fails loudly if any `cap-*` resource or PVC remains.

## 5. Break-glass

When the app is down and you need it back now, in order of least to most destructive:

1. **Restart the app:** `kubectl -n cap rollout restart deploy/cap-web`
2. **DB not reachable / cap-web crash-loops on migrate:** check MySQL:
   `kubectl -n cap get pods; kubectl -n cap logs cap-mysql-0 -c mysql`. The wait-for-mysql
   initContainer holds cap-web until MySQL answers, so a crash-loop usually means MySQL
   itself is down — fix that first.
3. **Egress unexpectedly needed (customer enabled a feature):** the symptom is a proxy
   `DENY` in the log for a real host. Add the host to `allowlist.yaml` (`optional`), update
   the proxy allowlist, `kubectl -n halden-platform rollout restart deploy/egress-proxy`.
   Never disable the proxy or the default-deny policy — add the one host.
4. **Storage full:** the object store or MySQL PVC filled. Free space or resize the PVC
   (`kubectl -n cap edit pvc data-cap-minio-0`) if your StorageClass allows expansion.
5. **Total loss:** restore from backup into a fresh install (§1 then §7).

Do **not** "fix forward" during a change freeze. Roll back (§3).

## 6. Backup

Automatic: the `cap-mysql-backup` CronJob dumps MySQL nightly to the in-cluster S3
bucket (`s3://cap/backups/`). Nothing leaves the network.

On demand:
```
STAMP=$(date +%Y%m%d-%H%M%S) LOCAL=1 ./scripts/backup.sh   # writes ./backups/cap-<stamp>.sql
```

## 7. Restore

```
# copy a dump into the mysql pod and load it
kubectl -n cap cp <dump>.sql cap-mysql-0:/tmp/restore.sql -c mysql
kubectl -n cap exec -it cap-mysql-0 -c mysql -- \
  sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < /tmp/restore.sql'
```
Restore recordings (object data) with `aws s3 sync` from your backup location to the
bucket if they were separately backed up.

## 8. Mirror + sign images into the private registry

Run on a bastion with temporary egress (the only place that needs the install-time
allowlist):
```
export REGISTRY=<your-registry>/cap
export COSIGN_PASSWORD=<key password>
export CAP_SRC=/path/to/Cap        # to also build media-server
./supply-chain/mirror.sh
```
This pulls, retags, pushes, **cosign-signs (offline)**, SBOMs, and verifies every image.
Then install with `--set global.imageRegistry=$REGISTRY`.

Rotate the signing key: generate a new pair (`cosign generate-key-pair`), re-run
`mirror.sh`, update `cosign.pub` everywhere it's referenced
(`platform/policies/kyverno-verify-images.yaml`), and redistribute the public key.

## 9. Metrics onboarding (customer scrapes us)

See `docs/metrics.md`. Short version: everything exposes Prometheus metrics on a pull
basis; point your Prometheus at the annotated services or apply the shipped
ServiceMonitors. Nothing is pushed anywhere.

## 10. Common failures and what they mean

| Symptom | Cause | Fix |
|---|---|---|
| cap-web `CrashLoopBackOff`, log "migrations" then exit | MySQL not ready in time | check `cap-mysql-0`; the initContainer should prevent this — MySQL is likely down |
| Pod `ImagePullBackOff` | image not in the private registry, or wrong `global.imageRegistry` | re-run mirror (§8); check pull secret |
| Pod rejected: "must set securityContext…" | restricted PodSecurity | the chart is compliant; a custom manifest isn't — add non-root/seccomp/drop-caps |
| Pod rejected: "not from an allowed registry" / "not pinned" | admission policy | use the private registry and a pinned tag/digest |
| App can't reach an external service | default-deny + proxy | add the host to `allowlist.yaml` optional (§5.3) — never disable the cage |
| Playback broken (video won't load) | S3 public endpoint unreachable or http/https mismatch | check the S3 ingress host resolves and matches `s3PublicUrl` |
