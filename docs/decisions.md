# Decisions

Each entry: the call, the rejected alternative, the tradeoff. Format is deliberately blunt.

## Framing: two planes

The brief is under-specified on purpose. The organizing call: the install must **assume
nothing** about the customer cluster — not the CNI, ingress, StorageClass, registry, or
IdP. So the work splits into a **platform plane** (the cage, cluster-scoped, simulates the
customer) and a **tenant plane** (the install, one namespace, no cluster-specific coupling;
every dependency is a Helm value with a default).

## Reconstructing the customer from a vague kickoff

| Unknown | Call | Reason |
|---|---|---|
| Cloud | kind cage + GKE as the two targets | cage holds the constraints; GKE proves portability |
| CNI | none assumed; enforce with `NetworkPolicy` + a proxy | CNI-specific policy (Cilium FQDN) is a bet that won't transfer |
| Ingress controller | bring-none; Ingress object only, controller is a prereq | brief says presence is unknown |
| StorageClass | none assumed; cluster default + pluggable | `standard`/`premium-rwo` may not exist |
| Registry | any OCI registry; `image.registry` is a value | could be Artifact Registry / ECR / ACR / Nexus / Harbor |
| CRDs allowed? | not required; native `ValidatingAdmissionPolicy` | signature verification (Kyverno) is layered only where present |

## Object store: MinIO → SeaweedFS

Chosen: SeaweedFS (S3-compatible). Rejected: MinIO (Cap's default), Zenko CloudServer.
Reason: MinIO withdrew its public container images in 2025 — Docker Hub and quay both
refuse anonymous pulls, which breaks Cap's shipped stack for everyone. SeaweedFS is
publicly available, lightweight, S3-compatible, with native Prometheus metrics; Cap speaks
plain S3 so it is unchanged. Bucket bootstrap uses `aws-cli` (MinIO's `mc` is gone too).
Tradeoff: weaker bucket-policy fidelity than AWS S3; mitigated by namespace isolation and a
read-only public S3 ingress. Lesson kept: upstream availability is a supply-chain risk,
which is why every image is mirrored and pinned.

## Egress proxy: mitmproxy

Chosen: mitmproxy as the TLS-intercepting forward proxy. Rejected: Squid with ssl-bump.
Reason: the available `ubuntu/squid` image lacks the ssl-bump certgen helper, so
reproducible interception was not possible. mitmproxy enforces the identical contract
(forward proxy, default-deny allowlist, TLS interception with a CA the client must trust,
full logging). Tradeoff: not what a real SOC runs; the install only couples to the
contract, not the product. A real customer's Squid/Zscaler imposes the same contract.

## Enforcement: NetworkPolicy + proxy, not Cilium

Chosen: default-deny egress `NetworkPolicy` (DNS + proxy + in-namespace only) plus the
proxy for the L7 allowlist and interception. Rejected: Cilium FQDN egress. Reason:
CNI-agnostic. Verified the plain-`NetworkPolicy` cage blocks off-namespace traffic.

## Admission: native VAP first, Kyverno for signatures

Chosen: native `ValidatingAdmissionPolicy` (CEL, no controller) for private-registry-only
and no-`:latest`; Kyverno `verifyImages` for cosign signatures, applied only where Kyverno
exists. Reason: structural rules need no controller (assume nothing); signature checks need
one, so that dependency stays off the critical path. Tradeoff: two engines.

## Signing: cosign, offline

Chosen: `cosign sign --tlog-upload=false` with a key pair; verify with the committed
public key. Rejected: keyless/Rekor. Reason: keyless signing contacts Sigstore, which
violates default-deny egress on an air-gapped bastion. Tradeoff: the signer owns key
distribution/rotation (documented in the runbook).

## No managed cloud services

Chosen: MySQL and the object store run in-cluster on both targets; only the StorageClass
differs. Rejected: Cloud SQL + GCS. Reason: full portability and the real "abstraction is
not hand-fitted" test; fits a regulated customer that will not use managed data services.
Tradeoff: the operator owns DB/object-store ops — mitigated by the backup CronJob; HA is a
documented upgrade.

## Task runner: Make

Chosen: `Makefile` for the local demo. Rejected: Taskfile. Reason: `make` needs no install.
The operational runbook uses plain `helm`/`kubectl`/`terraform`, not `make`, so the
customer's on-call does not depend on the demo tooling.

## Second target — proven on real GKE

The same chart was deployed to a real GKE cluster (an isolated `cap-selftest`
namespace): SeaweedFS + MySQL came up with PVCs bound on GKE Persistent
Disks (`standard-rwo`, pd.csi), migrations ran, and cap-web served HTTP 200 — then it was
torn down (namespace deleted, PDs reclaimed). Evidence: `evidence/gke-target.txt`. Only the
values profile and the StorageClass differed from kind; the chart was unchanged. The
Terraform `envs/gke` module (Artifact Registry + Workload Identity + tenant) is authored and
`validate`-clean; the live proof above used Helm directly against the existing cluster.

## Cut — stated plainly, nothing oversold

- **media-server: build+sign path proven, but no working image from this host.** No public
  image; build needs `apt` + `bun install`. On the dev host `apt` works but `bun install` is
  only intermittently reachable — even a retry build produced an image missing a runtime dep
  (`hono`) that crash-loops. The mechanics are proven (built, cosign-signed offline, SBOM
  generated); a working image needs one clean `bun install` on a machine with reliable egress
  (`CAP_SRC=/path/to/Cap ./supply-chain/mirror.sh`). Optional in the chart (default off on
  kind). Consequence: the air-gap proof covers web+DB+S3, not the media pipeline.
- **Ingress controller is a prerequisite, not shipped.** The chart creates the Ingress
  object only. Using ingress means mirroring the controller images (ingress-nginx +
  kube-webhook-certgen) too.
- **HA** for MySQL/object store — single replica + backups; HA documented, not built.
- **Live Kyverno signature enforcement on kind** — signatures proven via `cosign verify`;
  the Kyverno policy ships but Kyverno is not installed on the dev host, so the enforced
  image control on kind is the native VAP.
