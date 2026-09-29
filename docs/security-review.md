# Security review — Cap

For a reviewer with veto power who does not trust the vendor. Every egress has a reason,
every permission a justification, every image an independent verification path. Claims are
verifiable with the commands inline and the files in `evidence/`.

Scope: the tenant install in namespace `cap` and the platform controls that constrain it.

## 1. Data crossing the boundary: none

The install makes no unconditional outbound calls at runtime.

- The proxy's permanent allowlist is empty (`allowlist.yaml`, `permanent: []`).
- With the proxy in full deny, cap-web still serves HTTP 200 (`evidence/air-gap-proof.txt`).
- The denial log shows real blocks, not an empty file (`evidence/proxy-denials.log`).

Two independent layers enforce this:

1. Default-deny egress `NetworkPolicy` (`platform/netpol/egress.yaml`): pods in `cap` egress
   only to DNS, the proxy, and same-namespace pods. Verify:
   ```
   kubectl exec -n cap deploy/cap-web -c web -- \
     node -e 'require("net").connect(443,"10.96.0.1",()=>console.log("OPEN")).on("error",()=>console.log("BLOCKED"))'
   # BLOCKED
   ```
2. Forward proxy, default-deny allowlist (`platform/egress-proxy/`): the only egress path;
   denies and logs any non-allowlisted host.

The tenant cannot remove layer 1: `cap-deployer` has read-only access to NetworkPolicies.

## 2. Every egress, with its reason

| Scope | Hosts | Reason | Where |
|---|---|---|---|
| permanent | none | the install needs no runtime egress | — |
| install-time | ghcr.io, *.githubusercontent.com, registry-1.docker.io, auth.docker.io, production.cloudflare.docker.com, deb.debian.org, security.debian.org, registry.npmjs.org | pull/build images to mirror into the private registry | the bastion running `mirror.sh` only |
| optional | accounts.google.com, oauth2.googleapis.com (Google SSO); api.resend.com (email) | only if the customer enables that feature | cap-web |

Install-time hosts are never granted to the tenant namespace or the CI runner. Per-entry
detail (port, component, breaks-without-it) is in `allowlist.yaml`.

## 3. Every permission, with its justification

- Namespace-scoped RBAC only (`platform/rbac/tenant-rbac.yaml`): `cap-deployer` manages
  namespaced objects in `cap` and has no cluster power, and only read access to
  NetworkPolicies. Verify: `kubectl auth can-i get nodes --as=system:serviceaccount:cap:cap-deployer` → `no`.
- Workload pods run under the chart ServiceAccount with `automountServiceAccountToken:
  false`; nothing in Cap uses the API, so no token is mounted. Verify:
  `kubectl -n cap get pod -l app.kubernetes.io/component=web -o jsonpath='{.items[0].spec.serviceAccountName} {.items[0].spec.automountServiceAccountToken}'`
  → `cap false`.
- Restricted PodSecurity on `cap`: non-root, no privilege escalation, all capabilities
  dropped, seccomp `RuntimeDefault`. A root pod is rejected at admission.
- The proxy, registry, and policies live in `halden-platform`, which tenant RBAC cannot touch.

## 4. Independent image verification

Every mirrored image is cosign-signed and shipped with an SBOM. Verify against the
committed public key — no trust in the vendor's build required:

```
cosign verify --key supply-chain/cosign.pub --insecure-ignore-tlog=true \
  <registry>/cap/capsoftware/cap-web:mirrored-8ee4cbd
```

- Verifying with the published key passes; any other key fails (`evidence/image-verification.txt`).
- Signing is offline (`--tlog-upload=false`): no Sigstore/Rekor contact, no third-party trust.
- SBOMs (`supply-chain/sbom/*.spdx.json.gz`, SPDX/syft) allow independent content audit.

Admission enforcement (defense in depth):

- Native `ValidatingAdmissionPolicy` denies images not from an allowed registry, or
  `:latest`/unpinned. Refs must be fully qualified: `evil.example.com/x:1.0` and
  `docker.io/library/busybox:latest` are denied; `docker.io/library/busybox:1.36` is admitted.
- Kyverno `verifyImages` denies images under the private-registry prefix that lack a valid
  signature (applied where Kyverno is present).

Honest scope of admission:
- On kind, `allowedRegistries` is broadened to `docker.io/`+`ghcr.io/` because demo images
  are `kind load`ed from public sources, so kind is not literally private-registry-only. The
  production posture (allowlist = private prefix, `--set global.imageRegistry=<registry>`) is
  a one-line change, marked in the policy file.
- Kyverno signature enforcement matches only the private-registry prefix. Images from
  docker.io/ghcr.io (the kind path) are not signature-checked at admission; on kind
  signatures are verified out-of-band with `cosign verify`.

## 5. Data flows

```
user ──HTTPS──> ingress ──> cap-web ──┬──> MySQL (in-cluster PVC)
                                      ├──> SeaweedFS S3 (in-cluster PVC)
                                      └──> media-server (in-cluster)
playback ──HTTPS──> ingress (S3 host) ──> SeaweedFS (read-only GET)
```

- Application data and backups stay in-cluster on PersistentVolumes; nothing goes to a
  managed service or off-network.
- Secrets (`DATABASE_ENCRYPTION_KEY`, `NEXTAUTH_SECRET`, DB/S3 credentials) are generated at
  install into a Secret, never committed, reused across upgrades (not rotated mid-life —
  that would break decryption). External secret managers via `secrets.existingSecret`.

## 6. TLS interception

The customer proxy terminates TLS with its own CA. The chart injects that CA
(`NODE_EXTRA_CA_CERTS`) and routes egress through the proxy, so any enabled egress works
through interception instead of failing on a cert error. Opt-in (`egress.proxy.enabled`,
`egress.ca.enabled`); off in the air-gapped default.

## 7. Residual risks (declared)

- DNS is an open channel: egress to CoreDNS is allowed and CoreDNS forwards upstream, so a
  compromised pod could DNS-tunnel out. Close with a split-horizon resolver (no upstream) or
  an egress firewall on CoreDNS. Not yet closed.
- Admission does not cover `ephemeralContainers` (`kubectl debug`); impact limited because
  `cap-deployer` lacks that verb. Extend the VAP `matchConstraints` to close it.
- Air-gap proof covers web+DB+S3, not the media pipeline (media-server not built on kind).
- SeaweedFS open S3 auth in the cage default; mitigated by network isolation + read-only
  public ingress. Production: SeaweedFS identities or the customer's object store.
- Single-replica MySQL/object store — availability, not confidentiality; mitigated by backups.
- mitmproxy stands in for the customer's real proxy in the cage.
