# =============================================================================
# Cap-in-a-cage — one-command orchestration.
#
# Two targets: a local `kind` cage (simulates the customer) and a real cloud
# cluster (GKE). The install (Helm) is identical on both; only a values profile
# differs. See docs/runbook.md for the full operator guide.
#
# Tool binaries are overridable so this works in constrained environments:
#   make install KUBECTL="kubectl --context foo" HELM="helm"
# =============================================================================
SHELL      := /usr/bin/env bash
.ONESHELL:
.SHELLFLAGS := -euo pipefail -c

KUBECTL    ?= kubectl
HELM       ?= helm
KIND       ?= kind
CLUSTER    ?= halden
NAMESPACE  ?= cap
RELEASE    ?= cap
CHART      := install/helm/cap
PROFILE    ?= install/helm/cap/profiles/values-kind.yaml
REGISTRY   ?= localhost:5000/cap   # in-cluster private registry (see platform/registry)

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# ----------------------------------------------------------------------------
# The cage (platform plane)
# ----------------------------------------------------------------------------
.PHONY: up
up: cluster platform ## Create the kind cage and apply all platform (cage) policy
	@echo "Cage '$(CLUSTER)' is up and enforcing."

.PHONY: cluster
cluster: ## Create the kind cluster only
	$(KIND) create cluster --config platform/kind/cluster.yaml --wait 120s || true

.PHONY: platform
platform: ## Apply the platform/cage: storage, registry, proxy, policies, RBAC, netpol, constraints
	./scripts/platform-up.sh

.PHONY: load-images
load-images: ## (offline/air-gap) Pull base images on the host and load them into kind
	./scripts/load-images.sh

# ----------------------------------------------------------------------------
# The install (tenant plane)
# ----------------------------------------------------------------------------
.PHONY: install
install: ## Install/upgrade Cap into its namespace (idempotent)
	$(KUBECTL) create namespace $(NAMESPACE) --dry-run=client -o yaml | $(KUBECTL) apply -f -
	$(HELM) upgrade --install $(RELEASE) $(CHART) -n $(NAMESPACE) \
	  -f $(PROFILE) --atomic --wait --timeout 10m
	@echo "Cap installed. See: $(HELM) -n $(NAMESPACE) get notes $(RELEASE)"

.PHONY: verify
verify: ## Run the verification suite (cage bites, least-privilege, health)
	./scripts/verify.sh

.PHONY: air-gap
air-gap: ## Flip the egress proxy to FULL DENY and prove the app still serves
	./scripts/air-gap-assert.sh

# ----------------------------------------------------------------------------
# Reversibility
# ----------------------------------------------------------------------------
.PHONY: rollback
rollback: ## Roll back to the previous Helm revision
	$(HELM) rollback $(RELEASE) -n $(NAMESPACE) --wait --timeout 10m
	$(HELM) -n $(NAMESPACE) history $(RELEASE)

.PHONY: uninstall
uninstall: ## Uninstall Cap and prove nothing is left behind
	./scripts/uninstall.sh

.PHONY: down
down: ## Delete the whole kind cage
	$(KIND) delete cluster --name $(CLUSTER)

# ----------------------------------------------------------------------------
# Supply chain
# ----------------------------------------------------------------------------
.PHONY: mirror
mirror: ## Mirror + build + sign all images into the private registry
	./supply-chain/mirror.sh

.PHONY: lint
lint: ## Lint the Helm chart and render templates
	$(HELM) lint $(CHART)
	$(HELM) template $(RELEASE) $(CHART) -f $(PROFILE) >/dev/null && echo "template OK"
