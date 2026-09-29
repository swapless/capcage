# Runbook — Cap

Operational guide for the platform/on-call team running Cap in their own namespace.
Assumes `kubectl` + `helm` (and `terraform` for provisioning) against the target
cluster, and access to the private registry holding the mirrored images. It does not
assume the `make` targets — those are a local-demo convenience (see README).

Namespace: `cap`. Release: `cap`. Chart: the `cap` Helm chart from this repo
(`install/helm/cap`) or a chart repository it is published to.

## Prerequisites

- Images mirrored + signed into the private registry (see "Image mirroring" below).
- An ingress controller in the cluster if ingress is used (the chart ships the Ingress
  object only, not a controller).
- A StorageClass, or accept the cluster default.

## Install

```
helm upgrade --install cap <chart> -n cap --create-namespace \
  -f values-gke.yaml \
  --set global.imageRegistry=<registry>/cap \
  --set global.imagePullSecrets='{regcred}' \
  --atomic --wait --timeout 10m
```

`--atomic` rolls back automatically on failure. Migrations run in-process in cap-web on
startup. Progress:

```
kubectl -n cap get pods -w
kubectl -n cap logs deploy/cap-web -f          # "Migrations run successfully!"
```

Without an email provider, login codes print to the web log:

```
kubectl -n cap logs deploy/cap-web | grep -i login
```

## Upgrade

Rollback-not-fix-forward. Change window: Thursdays.

```
helm upgrade cap <chart> -n cap -f <values> --atomic --wait --timeout 10m
helm -n cap history cap
```

## Rollback (including from a half-applied state)

```
helm -n cap history cap                        # find last good REVISION
helm rollback cap <REVISION> -n cap --wait --timeout 10m
kubectl -n cap rollout status deploy/cap-web
```

DDL is not transactional in MySQL — a migration that dies part-way can leave the schema
half-changed. The backup is the safety net, not migration atomicity. If the database is
inconsistent:

```
kubectl -n cap scale deploy/cap-web --replicas=0     # stop writes
# restore the database (see "Restore")
helm rollback cap <REVISION> -n cap --wait            # revision matching the backup
kubectl -n cap scale deploy/cap-web --replicas=1
```

## Uninstall (leaves nothing)

`helm uninstall` does not delete StatefulSet PVCs. Back up first — data is destroyed.

```
# 1. back up (see Backup)
helm uninstall cap -n cap --wait
kubectl -n cap delete pvc -l app.kubernetes.io/name=cap
kubectl -n cap get pvc | grep -E 'data-cap-(mysql|minio)' | awk '{print $1}' | xargs -r kubectl -n cap delete pvc
kubectl -n cap get all,pvc,secret | grep cap- || echo CLEAN
```

## Break-glass

Least to most destructive:

1. Restart: `kubectl -n cap rollout restart deploy/cap-web`.
2. cap-web crash-loops on migrate: the DB is likely down. Check `cap-mysql-0`
   (`kubectl -n cap logs cap-mysql-0 -c mysql`); an initContainer holds cap-web until
   MySQL answers, so a loop means MySQL itself failed.
3. A feature needs egress (proxy `DENY` in the log for a real host): add the host to the
   `optional` section of `allowlist.yaml`, update the proxy allowlist ConfigMap, restart
   the proxy. Never disable the proxy or the default-deny policy — add the one host.
4. Storage full: free space or expand the PVC if the StorageClass allows it.
5. Total loss: reinstall, then restore from backup.

Do not fix-forward during a change freeze; roll back.

## Backup

Automatic: the `cap-mysql-backup` CronJob dumps MySQL nightly to the in-cluster S3
bucket (`s3://cap/backups/`). Nothing leaves the network.

On demand:

```
kubectl -n cap exec cap-mysql-0 -c mysql -- \
  sh -c 'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines --databases cap' \
  > cap-$(date +%F).sql
```

## Restore

```
kubectl -n cap cp <dump>.sql cap-mysql-0:/tmp/restore.sql -c mysql
kubectl -n cap exec -it cap-mysql-0 -c mysql -- \
  sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < /tmp/restore.sql'
```

## Image mirroring (into the customer's private registry)

Run on a host with temporary egress. Requires `docker`, `cosign`, `syft`, `yq`.

```
export REGISTRY=<registry>/cap          # e.g. REGION-docker.pkg.dev/PROJECT/cap
export COSIGN_PASSWORD=<key password>
export CAP_SRC=/path/to/Cap             # to also build the media-server image
./supply-chain/mirror.sh
```

Pulls, retags to `$REGISTRY/<repository>:<tag>`, pushes, cosign-signs (offline), and
writes SBOMs. Install then uses `--set global.imageRegistry=$REGISTRY`.

Key rotation: generate a new pair (`cosign generate-key-pair`), re-run `mirror.sh`,
replace the public key in `platform/policies/kyverno-verify-images.yaml` and
`supply-chain/cosign.pub`, redistribute.

## Metrics

Pull model — the customer's Prometheus scrapes the pods; nothing is pushed. Details and
scrape config: `docs/metrics.md`.

## Failure reference

| Symptom | Cause | Action |
|---|---|---|
| cap-web CrashLoop, log shows migrations then exit | MySQL not ready | check `cap-mysql-0` |
| Pod ImagePullBackOff | image absent / wrong `global.imageRegistry` / missing pull secret | re-mirror; fix registry value |
| Pod rejected: securityContext | restricted PodSecurity | run non-root, drop caps, seccomp |
| Pod rejected: registry / not pinned | admission policy | use the private registry, a pinned tag/digest |
| External call fails | default-deny + proxy | add the host to `allowlist.yaml` optional; never disable the cage |
| Playback broken | S3 public endpoint unreachable or http/https mismatch | check the S3 ingress host matches `s3PublicUrl` |
