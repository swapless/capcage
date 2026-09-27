# Target 2: real GKE dev cluster.
# Terraform provisions the CLOUD primitives (Artifact Registry + a Workload-Identity
# service account for pulls) and the k8s primitives (namespace/RBAC/quota) + Helm
# release. The cluster itself is EXISTING (consumed as a data source) — we don't own it.
terraform {
  required_providers {
    google     = { source = "hashicorp/google", version = ">= 5.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = ">= 2.30" }
    helm       = { source = "hashicorp/helm", version = ">= 2.14" }
  }
}

variable "project" {
  type = string
}
variable "region" {
  type    = string
  default = "us-central1"
}
variable "cluster_name" {
  type = string
}
variable "cluster_location" {
  type = string
}

provider "google" {
  project = var.project
  region  = var.region
}

# Existing dev cluster — data source, not managed here.
data "google_container_cluster" "dev" {
  name     = var.cluster_name
  location = var.cluster_location
}

data "google_client_config" "default" {}

# --- Cloud primitive: a private Artifact Registry for the mirrored, signed images.
resource "google_artifact_registry_repository" "cap" {
  location      = var.region
  repository_id = "cap"
  format        = "DOCKER"
  description   = "Mirrored, cosign-signed Cap images"
}

# --- Cloud primitive: a service account the nodes/pods use to pull (Workload Identity).
resource "google_service_account" "puller" {
  account_id   = "cap-image-puller"
  display_name = "Cap image puller"
}

resource "google_artifact_registry_repository_iam_member" "puller" {
  location   = google_artifact_registry_repository.cap.location
  repository = google_artifact_registry_repository.cap.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.puller.email}"
}

# Providers pointed at the existing cluster.
provider "kubernetes" {
  host                   = "https://${data.google_container_cluster.dev.endpoint}"
  cluster_ca_certificate = base64decode(data.google_container_cluster.dev.master_auth[0].cluster_ca_certificate)
  token                  = data.google_client_config.default.access_token
}

provider "helm" {
  kubernetes = {
    host                   = "https://${data.google_container_cluster.dev.endpoint}"
    cluster_ca_certificate = base64decode(data.google_container_cluster.dev.master_auth[0].cluster_ca_certificate)
    token                  = data.google_client_config.default.access_token
  }
}

module "tenant" {
  source         = "../../modules/tenant"
  namespace      = "cap"
  chart_path     = "${path.module}/../../../helm/cap"
  values_file    = "${path.module}/../../../helm/cap/profiles/values-gke.yaml"
  image_registry = "${var.region}-docker.pkg.dev/${var.project}/cap"
}
