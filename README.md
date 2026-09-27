# Cap in a cage

Deploy **Cap** (an open-source screen recorder that ships only as docker-compose) into a
locked-down enterprise Kubernetes environment — default-deny egress, a TLS-intercepting
proxy, private-registry-only, admission control, namespace-scoped RBAC — and prove it runs
with **nothing relaxed**.

The app is not the assignment. The install is. We don't modify Cap; everything here lives
in the gap between "runs on my laptop" and "runs inside a customer's cloud, under policies
we didn't write, on a cluster we didn't build."

## What's proven (see `evidence/`)

- **Air-gap:** with the egress proxy in *full deny*, the app still serves HTTP 200
  (`evidence/air-gap-proof.txt`). The permanent egress allowlist is **empty**.
- **The cage bites:** default-deny `NetworkPolicy` blocks off-namespace traffic; the proxy
  denies and logs non-allowlisted egress (`evidence/proxy-denials.log`).
- **Verify our images without trusting us:** cosign signatures verify with our public key
  and fail with any other (`evidence/image-verification.txt`); SBOMs in `supply-chain/sbom/`.
- **Admission control:** off-registry and `:latest` images are rejected; the whole install
  is policy-compliant (`evidence/verify.txt`).

## Two targets, one chart

| | Local cage (`kind`) | Real cloud (`GKE`) |
|---|---|---|
| Cluster | `platform/kind` | your GKE dev cluster |
| Storage | local default StorageClass | your StorageClass (pluggable) or local |
| Registry | in-cluster `registry:2` | your Artifact Registry / ECR / ACR / Nexus |
| Profile | `profiles/values-kind.yaml` | `profiles/values-gke.yaml` |

The install assumes **nothing** about the cluster — not the CNI, ingress, StorageClass,
or registry. Every dependency is a value with a self-contained default.

## Quickstart (local cage)

```
make up            # create the kind cage + apply all platform policy (proxy, netpol, RBAC, admission)
make load-images   # (this host / air-gap) pull base images and load them into the cluster
make install       # deploy Cap into its namespace
make verify        # prove the cage bites and the app is healthy
make air-gap       # flip the proxy to full deny and prove the app still serves
```

Reach the app: `kubectl -n cap port-forward svc/cap-web 3000:3000` → http://localhost:3000
(login code prints to `kubectl -n cap logs deploy/cap-web`).

Deploy to a real registry + cloud:
```
./supply-chain/mirror.sh                       # mirror+sign images into your registry
helm upgrade --install cap install/helm/cap -n cap --create-namespace \
  -f install/helm/cap/profiles/values-gke.yaml \
  --set global.imageRegistry=<your-registry>/cap --atomic --wait
```

## Layout

```
platform/     the cage (cluster-scoped, simulates the customer)
  kind/         kind cluster config
  egress-proxy/ mitmproxy: TLS interception + default-deny allowlist + denial log
  netpol/       default-deny egress NetworkPolicy
  rbac/         namespace-scoped tenant RBAC (no cluster-admin)
  constraints/  restricted PodSecurity, ResourceQuota, LimitRange
  policies/     ValidatingAdmissionPolicy + Kyverno verifyImages
  registry/     in-cluster private registry
install/      the tenant install (one namespace, assumes nothing)
  helm/cap/     the chart (web, media-server, mysql, object store, backups, metrics)
  terraform/    cloud + k8s primitives, per-target envs
supply-chain/ mirror.sh + images.yaml + cosign.pub + SBOMs
allowlist.yaml  every egress entry: fqdn, port, component, breaks-without-it, scope
evidence/     committed proofs (denial log, air-gap, image verification, verify run)
docs/         decisions.md · runbook.md · security-review.md · metrics.md
scripts/      platform-up · load-images · verify · air-gap-assert · rollback · uninstall · backup
```

## Docs

- **[decisions.md](docs/decisions.md)** — every real call, what we rejected, the tradeoff.
- **[runbook.md](docs/runbook.md)** — install/upgrade/rollback/uninstall/break-glass/backup.
- **[security-review.md](docs/security-review.md)** — approve it without a call with us.
- **[metrics.md](docs/metrics.md)** — how you scrape us (pull; nothing leaves).

## Notes on this dev host

The machine this was built on firewalls host↔docker-bridge traffic, so `kubectl`/`helm`
are driven from a container on the kind network and images are pulled on the host then
`kind load`ed (mirroring the air-gap pattern). On a normal machine or GKE, use
`kubectl`/`helm` directly. Also: MinIO withdrew its public images in 2025, so the object
store is SeaweedFS (S3-compatible) — see decisions.md.
