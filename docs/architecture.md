# Architecture

Two planes. The **platform plane** is the cage (the customer's environment, simulated). The
**tenant plane** is the install — one namespace, assumes nothing about the cluster.

```mermaid
flowchart TB
  user([end user]):::ext

  subgraph platform["PLATFORM PLANE — the cage (customer-owned, cluster-scoped)"]
    direction TB
    proxy["egress-proxy · mitmproxy<br/>TLS intercept + default-deny allowlist + denial log"]:::plat
    admission["admission<br/>ValidatingAdmissionPolicy + Kyverno verifyImages"]:::plat
    registry["private registry"]:::plat
    runner["CI runner<br/>no egress"]:::plat
    rbac["namespace-scoped RBAC<br/>no cluster-admin"]:::plat
  end

  subgraph tenant["TENANT PLANE — namespace cap (the install)"]
    direction TB
    ingress["ingress"]:::ten
    web["cap-web · Next.js<br/>runs DB migrations on start"]:::ten
    ms["media-server · FFmpeg"]:::ten
    db[("MySQL<br/>StatefulSet + PVC")]:::ten
    s3[("SeaweedFS S3<br/>StatefulSet + PVC")]:::ten
  end

  internet([internet]):::ext

  user -->|HTTPS| ingress --> web
  web --> db
  web --> s3
  web --> ms
  ms --> s3

  web -. all egress .-> netpol{{"default-deny NetworkPolicy<br/>DNS + proxy + in-namespace only"}}:::gate
  netpol -. only path out .-> proxy
  proxy -. "allowlist empty ⇒ DENY (air-gap)" .-> internet

  admission -. gates pods .-> tenant
  registry -. pulls .-> tenant
  rbac -. scopes .-> tenant

  classDef plat fill:#1f2a44,stroke:#4a5a80,color:#e8ecf5;
  classDef ten fill:#123a2e,stroke:#2f7d5f,color:#e6f5ee;
  classDef gate fill:#4a2020,stroke:#a05050,color:#f5e6e6;
  classDef ext fill:#2a2a2a,stroke:#666,color:#ddd;
```

Enforcement is CNI-agnostic: a plain default-deny `NetworkPolicy` forces all egress through
the proxy (the only allowed path), and the proxy does the L7 allowlist + TLS interception +
logging. With the allowlist empty, nothing egresses — the app still serves (air-gap).

## Supply chain

The repo ships the recipe and the public key, not the images. A bastion with temporary
egress mirrors every image into the customer's private registry, signs it offline, and
writes an SBOM; the customer verifies with the public key alone.

```mermaid
flowchart LR
  up([public sources<br/>ghcr.io / docker.io / Cap source]):::ext
  bastion["bastion · mirror.sh<br/>pull / build · cosign sign offline · syft SBOM"]:::plat
  reg["private registry<br/>customer-owned"]:::plat
  adm["admission<br/>registry + no-latest + signature"]:::gate
  pod["tenant pod"]:::ten

  up -->|"install-time egress (bastion only)"| bastion
  bastion -->|push signed| reg
  reg -->|pull| pod
  adm -. verifies .-> pod
  cust([customer]):::ext -. "cosign verify --key cosign.pub" .-> reg

  classDef plat fill:#1f2a44,stroke:#4a5a80,color:#e8ecf5;
  classDef ten fill:#123a2e,stroke:#2f7d5f,color:#e6f5ee;
  classDef gate fill:#4a2020,stroke:#a05050,color:#f5e6e6;
  classDef ext fill:#2a2a2a,stroke:#666,color:#ddd;
```

## Two targets

The same chart runs on both; only a values profile differs (kind uses `kind load`ed public
images; GKE pulls from the customer registry via `global.imageRegistry`). Image refs are
identical modulo the registry prefix — verified with `helm template`.
