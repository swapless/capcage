# Cap in a cage

Deploy Cap (an open-source screen recorder shipped only as docker-compose) into a
locked-down Kubernetes environment: default-deny egress, a TLS-intercepting proxy,
admission control, namespace-scoped RBAC, private-registry pulls.

## Layout

- `platform/` — the cage (cluster-scoped): kind cluster, mitmproxy egress proxy + CA,
  default-deny NetworkPolicy, in-cluster registry, admission policies, tenant RBAC,
  no-outbound CI runner, restricted PodSecurity + quotas.
- `install/` — the tenant install: Helm chart (`install/helm/cap`) + Terraform
  (`install/terraform`, kind + GKE). Assumes nothing about the cluster: CNI, ingress,
  StorageClass, and registry are all values with defaults.

## Images & registry

The repo ships the recipe and the public signing key, not the images.

- kind: `scripts/load-images.sh` pulls public images to the host and `kind load`s them.
- Real deploy: `supply-chain/mirror.sh REGISTRY=<registry>/cap` mirrors each image into a
  private registry (Artifact Registry / ECR / ACR / Harbor / Nexus), cosign-signs offline,
  and writes SBOMs. Install with `--set global.imageRegistry=<registry>/cap`.
- `media-server` has no public image; `mirror.sh` builds it from Cap source (`CAP_SRC=...`).

## Proven (`evidence/`)

| Claim | File |
|---|---|
| App serves HTTP 200 with the proxy in full deny | `air-gap-proof.txt` |
| Egress denied + logged | `proxy-denials.log` |
| Images verify with the public key, fail with any other | `image-verification.txt` |
| Rollback recovers a half-applied upgrade | `rollback-proof.txt` |
| Uninstall leaves nothing | `uninstall-proof.txt` |
| Runner has no way out | `ci-runner-no-egress.txt` |
| Second target (real GKE, then torn down) | `gke-target.txt` |
| Recorded install | `install.cast` (`asciinema play`) |
| Full suite | `verify.txt` |

## Quickstart (kind)

Requires docker, kind, kubectl, helm, host internet (to fetch public images once).

```
make up            # create the cage + apply platform policy
make load-images   # pull public images and load into kind
make install       # deploy Cap
make verify        # cage bites; app healthy
make air-gap       # proxy full-deny; app still serves
```

App: `kubectl -n cap port-forward svc/cap-web 3000:3000`. Login code:
`kubectl -n cap logs deploy/cap-web`.

## Real deploy

Install/upgrade/rollback/uninstall/break-glass/backup/mirroring: `docs/runbook.md`
(plain `helm`/`kubectl`/`terraform`).

## Docs

- `docs/architecture.md` — diagrams (two planes, egress, supply chain).
- `docs/decisions.md` — calls made, alternatives, tradeoffs, cuts.
- `docs/runbook.md` — operations, for the on-call.
- `docs/security-review.md` — egress + permissions justified; image verification; residual risks.
- `docs/metrics.md` — customer-scraped metrics (pull).

## Notes

- Two targets: kind end-to-end, and the same chart on real GKE (PVCs on Persistent Disks,
  migrations, HTTP 200), then torn down (`evidence/gke-target.txt`).
- Object store is SeaweedFS (MinIO withdrew its public images in 2025 — `docs/decisions.md`).
