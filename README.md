# Cap in a cage

Deploy Cap (an open-source screen recorder shipped only as docker-compose) into a
locked-down enterprise Kubernetes environment and prove it runs with nothing relaxed:
default-deny egress, a TLS-intercepting proxy, admission control, namespace-scoped RBAC,
private-registry pulls. The app is not the assignment; the install is.

## Two planes

- `platform/` — the cage (cluster-scoped, simulates the customer): kind cluster,
  mitmproxy egress proxy + CA, default-deny NetworkPolicy, in-cluster registry, admission
  policies, tenant RBAC, no-outbound CI runner, restricted PodSecurity + quotas.
- `install/` — the tenant install: a Helm chart (`install/helm/cap`) and Terraform
  (`install/terraform`, kind + GKE). Assumes nothing about the cluster — CNI, ingress,
  StorageClass, and registry are all values with self-contained defaults.

## Images & registry

The repo ships the recipe and the public signing key, not the images.

- Local cage (kind): `scripts/load-images.sh` pulls the public base images to the host and
  loads them into kind with `kind load`. No registry involved.
- Real deploy: `supply-chain/mirror.sh REGISTRY=<customer registry>/cap` mirrors every
  image into the customer's private registry (Artifact Registry / ECR / ACR / Harbor /
  Nexus), cosign-signs each (offline), and writes SBOMs. Install with
  `--set global.imageRegistry=<customer registry>/cap`.
- `media-server` has no public image; `mirror.sh` builds it from Cap source (`CAP_SRC=...`).

## Proven (evidence/)

| Claim | File |
|---|---|
| App serves HTTP 200 with the proxy in full deny | `air-gap-proof.txt` |
| Egress denied + logged | `proxy-denials.log` |
| Images verify with the public key, fail with any other | `image-verification.txt` |
| Rollback recovers a half-applied upgrade | `rollback-proof.txt` |
| Uninstall leaves nothing | `uninstall-proof.txt` |
| Runner has no way out | `ci-runner-no-egress.txt` |
| Full suite | `verify.txt` |

## Local demo (kind)

Requires docker, kind, kubectl, helm, and host internet (to fetch public images once).

```
make up            # create the kind cage + apply platform policy
make load-images   # pull public images to the host and load into kind
make install       # deploy Cap
make verify        # prove the cage bites and the app is healthy
make air-gap       # proxy full-deny; app still serves
```

Reach the app: `kubectl -n cap port-forward svc/cap-web 3000:3000`. Login code:
`kubectl -n cap logs deploy/cap-web`.

## Real deploy (customer cluster)

Operational procedures — install, upgrade, rollback, uninstall, break-glass, backup,
mirroring — are in `docs/runbook.md` and use plain `helm`/`kubectl`/`terraform`, not `make`.

## Docs

- `docs/decisions.md` — the calls made, rejected alternatives, tradeoffs, what was cut.
- `docs/runbook.md` — operations, for the customer's on-call.
- `docs/security-review.md` — every egress and permission justified; independent image
  verification; residual risks.
- `docs/metrics.md` — how the customer scrapes metrics (pull; nothing leaves).

## Scope notes

- Two targets: kind is exercised end-to-end; the GKE Terraform is authored and
  `validate`-clean but not applied to a live cluster (see decisions.md).
- Object store is SeaweedFS: MinIO withdrew its public images in 2025 (decisions.md).
- The dev host firewalls the docker bridge, so `kubectl`/`helm` were driven from a
  container on the kind network and images `kind load`ed; irrelevant on a normal cluster.
