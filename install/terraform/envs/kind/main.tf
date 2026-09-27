# Target 1: local kind cage. Providers point at the kind kubeconfig context.
terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = ">= 2.30" }
    helm       = { source = "hashicorp/helm", version = ">= 2.14" }
  }
}

variable "kube_context" {
  type    = string
  default = "kind-halden"
}

provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = var.kube_context
}

provider "helm" {
  kubernetes = {
    config_path    = "~/.kube/config"
    config_context = var.kube_context
  }
}

module "tenant" {
  source         = "../../modules/tenant"
  namespace      = "cap"
  chart_path     = "${path.module}/../../../helm/cap"
  values_file    = "${path.module}/../../../helm/cap/profiles/values-kind.yaml"
  image_registry = "" # kind uses loaded images; set to your in-cluster registry if pushing
}
