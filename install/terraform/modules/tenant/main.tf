# Tenant module: the k8s primitives the install needs in ONE namespace, plus the
# Helm release. Cloud-agnostic — the envs wire the providers. "Terraform for
# primitives (namespace, RBAC, quota), Helm for the workload."
terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = ">= 2.30" }
    helm       = { source = "hashicorp/helm", version = ">= 2.14" }
  }
}

resource "kubernetes_namespace_v1" "tenant" {
  metadata {
    name = var.namespace
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
}

resource "kubernetes_resource_quota_v1" "quota" {
  metadata {
    name      = "cap-quota"
    namespace = kubernetes_namespace_v1.tenant.metadata[0].name
  }
  spec {
    hard = {
      "requests.cpu"           = "3"
      "requests.memory"        = "6Gi"
      "limits.cpu"             = "8"
      "limits.memory"          = "10Gi"
      "pods"                   = "20"
      "persistentvolumeclaims" = "6"
      "requests.storage"       = "60Gi"
    }
  }
}

# Namespace-scoped deployer identity — no cluster-admin.
resource "kubernetes_service_account_v1" "deployer" {
  metadata {
    name      = "cap-deployer"
    namespace = kubernetes_namespace_v1.tenant.metadata[0].name
  }
}

resource "kubernetes_role_v1" "deployer" {
  metadata {
    name      = "cap-deployer"
    namespace = kubernetes_namespace_v1.tenant.metadata[0].name
  }
  rule {
    api_groups = [""]
    resources  = ["pods", "services", "configmaps", "secrets", "persistentvolumeclaims", "serviceaccounts"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  rule {
    api_groups = ["apps", "batch", "networking.k8s.io"]
    resources  = ["deployments", "statefulsets", "jobs", "cronjobs", "ingresses", "networkpolicies"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
}

resource "kubernetes_role_binding_v1" "deployer" {
  metadata {
    name      = "cap-deployer"
    namespace = kubernetes_namespace_v1.tenant.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.deployer.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.deployer.metadata[0].name
    namespace = kubernetes_namespace_v1.tenant.metadata[0].name
  }
}

# The workload — same chart on every target; only the values profile differs.
resource "helm_release" "cap" {
  name      = "cap"
  namespace = kubernetes_namespace_v1.tenant.metadata[0].name
  chart     = var.chart_path
  values    = [file(var.values_file)]

  # helm provider v3: `set` is a list attribute, not a block.
  set = var.image_registry == "" ? [] : [{
    name  = "global.imageRegistry"
    value = var.image_registry
  }]
  atomic     = true
  wait       = true
  timeout    = 600
  depends_on = [kubernetes_resource_quota_v1.quota]
}
