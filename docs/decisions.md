# Decisions

For each real call: what we chose, what we rejected, the tradeoff we accepted, and
what we cut. The brief is deliberately under-specified; these are the calls nobody
made for us.

---

## The customer told us almost nothing. What we assumed, and why.

Halden's kickoff gave us constraints, not facts. We made these calls and wrote them
down rather than block on answers their platform team wouldn't have given either:

| Unknown | Call | Why |
|---|---|---|
| Which cloud | Local **kind** cage + real **GKE** as the two targets | The cage is where the constraints live; GKE proves the abstraction is real on a cloud. |
| Which CNI | **Assume none.** Enforce with plain `NetworkPolicy` + a forward proxy. | The customer's CNI is unknown; anything CNI-specific (Cilium FQDN policy) would be a bet we can't make. Verified plain `NetworkPolicy` bites on kindnet. |
| Ingress controller present? | **Bring our own**, toggleable | Brief says this is unknown. We ship one but let the customer disable it and use theirs. |
| Which StorageClass | **Assume none.** Local default + pluggable. | `standard`/`premium-rwo` may not exist. We bind on the cluster default and expose `persistence.storageClassName`/`existingClaim`. |
| Which registry | **Any OCI registry.** `image.registry` is a value. | Could be Artifact Registry, ECR, ACR, Nexus, Harbor. We don't hard-code one. |
| Can we run a CRD? | **Not required.** Native `ValidatingAdmissionPolicy` for structural rules. | If we can't install CRDs/controllers, the install still works. Kyverno (for signature verification) is layered on *only where present*. |

The principle underneath all of these: **the install assumes nothing about the
customer cluster.** Every external dependency is a value with a self-contained default.

---

## Object store: MinIO → SeaweedFS  *(forced, and it turned out to be a good story)*

**Chosen:** SeaweedFS (`chrislusf/seaweedfs`), S3-compatible.
**Rejected:** MinIO (Cap's default), Zenko CloudServer.
**Why:** MinIO **withdrew its public container images in 2025** — `minio/minio` and
`minio/mc` on Docker Hub and `quay.io/minio/minio` all refuse anonymous pulls. This
breaks Cap's shipped compose stack for anyone, not just us. SeaweedFS is a lightweight,
publicly-available, S3-compatible server with native Prometheus metrics. Cap speaks
plain S3 (`CAP_AWS_*`, `S3_PATH_STYLE=true`) so it works unchanged; bucket bootstrap
uses `aws-cli` in place of `mc`.
**Tradeoff:** SeaweedFS's bucket-policy fidelity is weaker than AWS S3; we rely on
namespace isolation + the public S3 ingress being read-only for playback rather than
fine-grained bucket policies. Zenko has fuller S3 semantics but is heavier and its
metrics story is weaker.
**The lesson we kept:** upstream availability is itself a supply-chain risk. This is
exactly why we **mirror and pin every image** into a private registry — see security-review.

## Egress proxy: mitmproxy (simulating the customer's Squid/Zscaler)

**Chosen:** mitmproxy as the TLS-intercepting forward proxy in the cage.
**Rejected:** Squid with ssl-bump.
**Why:** A real customer runs Squid/Zscaler. mitmproxy enforces the *identical
properties* — forward proxy, default-deny allowlist, TLS interception with a CA the
client must trust, full request logging — with a reproducible, scriptable config. The
available `ubuntu/squid` image ships without the ssl-bump certgen helper, so full TLS
interception with Squid wasn't reproducible here.
**Tradeoff:** mitmproxy is not what a Fortune-500 SOC runs in prod. The *contract* it
imposes on our install (trust this CA, go through this proxy, get allowlisted or
denied) is the same, and that contract is all our install actually couples to.

## Enforcement backbone: NetworkPolicy + proxy, not Cilium

**Chosen:** default-deny egress `NetworkPolicy` (only DNS + proxy + in-namespace) plus
the forward proxy for the allowlist + TLS interception.
**Rejected:** Cilium `CiliumNetworkPolicy`/FQDN egress.
**Why:** CNI-agnostic. Cilium FQDN policy is elegant but bakes in a CNI the customer
may not run. Verified the plain-`NetworkPolicy` cage actually blocks (off-namespace
connections time out; in-namespace connect).
**Cut:** per-FQDN *network-layer* egress rules. FQDN allowlisting happens at the proxy
(layer 7), which is where TLS interception and logging have to happen anyway.

## Admission control: native ValidatingAdmissionPolicy first, Kyverno for signatures

**Chosen:** native `ValidatingAdmissionPolicy` (CEL, GA in k8s 1.30) for
private-registry-only and no-`:latest`/unpinned; Kyverno `verifyImages` for cosign
signature enforcement, applied only where Kyverno exists.
**Rejected:** Kyverno for everything.
**Why:** Structural rules need no controller — fits "assume nothing." Signature
verification genuinely needs a controller that can fetch signatures (VAP can't), so
that one capability is isolated to Kyverno and made optional.
**Tradeoff:** two policy engines. Accepted because it keeps the hard dependency
(Kyverno) off the critical path — the install is safe under the native policy alone.

## Signing: cosign, key-based, offline (no transparency log)

**Chosen:** `cosign sign --tlog-upload=false` with a key pair; verify with
`--insecure-ignore-tlog=true`.
**Rejected:** keyless / Rekor transparency-log signing.
**Why:** Keyless signing phones home to Fulcio/Rekor — which **violates default-deny
egress** on an air-gapped bastion. Key-based offline signing needs no internet. The
customer verifies with the committed `cosign.pub` alone.
**Tradeoff:** we own key distribution and rotation (documented in the runbook) instead
of leaning on Sigstore's public good infrastructure.

## No managed cloud services (no Cloud SQL / GCS)

**Chosen:** MySQL and the object store run **in-cluster on both targets**; only the
`StorageClass` differs.
**Rejected:** Cloud SQL + GCS on GKE.
**Why:** Full portability and no cloud lock-in — the same chart runs on kind and GKE,
which is exactly the "is your abstraction real or hand-fitted" test. It also fits a
regulated customer that won't hand data to managed services.
**Tradeoff:** we own DB/object-store operations (backup, HA) instead of outsourcing
them. Mitigated by the backup CronJob; HA paths documented as upgrades.

## Task runner: Make

**Chosen:** a `Makefile`. **Rejected:** Taskfile/`go-task`.
**Why:** `make` is already on every reviewer's and on-call's machine; Taskfile is one
more thing to install, which contradicts "assume nothing."

---

## What we cut (and would do next)

- **Distributed SeaweedFS / MySQL HA** — single-replica StatefulSets with backups.
  Documented the HA upgrade; didn't build it. Depth over breadth.
- **media-server in the local demo** — it has no public image and must be built from
  Cap source (apt + `bun install`), which needs reliable egress. The build recipe is in
  `supply-chain/mirror.sh`; it's optional in the chart (`mediaServer.enabled`). The web
  app, migrations, and S3 all work without it; recording post-processing needs it.
- **Live Kyverno signature enforcement on kind** — the signing/verification is proven
  with `cosign verify` (evidence/image-verification.txt); the Kyverno policy is shipped
  and documented but not installed on the constrained dev host.
