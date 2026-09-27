# Terraform — two targets, one workload

Terraform provisions the **primitives**; Helm ships the **workload**. The same
`modules/tenant` (namespace, quota, namespace-scoped RBAC, and the `helm_release`)
runs on both targets — only the env wires the providers and per-target primitives.

```
modules/tenant/     namespace + ResourceQuota + deployer RBAC + helm_release cap
envs/kind/          providers -> kind context; installs cap with values-kind.yaml
envs/gke/           google provider; Artifact Registry + Workload-Identity SA (cloud
                    primitives) + providers from the EXISTING dev cluster (data source);
                    installs cap with values-gke.yaml
```

Both envs `terraform validate` clean.

## Local (kind)
```
cd envs/kind
terraform init
terraform apply -var kube_context=kind-halden
```

## GKE (existing dev cluster)
```
cd envs/gke
terraform init
terraform apply \
  -var project=<gcp-project> \
  -var region=us-central1 \
  -var cluster_name=<dev-cluster> \
  -var cluster_location=<region-or-zone>
```
This creates the Artifact Registry repo + image-puller service account (the cloud
primitives), then installs Cap via Helm into the existing cluster. Mirror + sign images
into that registry first (`REGISTRY=<region>-docker.pkg.dev/<project>/cap ./supply-chain/mirror.sh`).

The cluster itself is a **data source** — we don't own or modify the customer's cluster,
matching the "namespace on a shared cluster, no cluster-admin" constraint.
