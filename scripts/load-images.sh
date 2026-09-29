#!/usr/bin/env bash
# Pull base images on the host (which has egress) and load them into the kind
# nodes' containerd (which does not). Mirrors the air-gap mirror.sh pattern: pull
# on a bastion, then make the images available to the cluster without node egress.
#
# Must stay in sync with supply-chain/images.yaml + the platform images. The kind
# profile pins cap-web to a non-:latest tag (admission policy forbids :latest), so
# we retag it here — the same thing mirror.sh does against a real registry.
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"

CAPWEB_TAG="mirrored-8ee4cbd"   # must match install/helm/cap/profiles/values-kind.yaml

# Tenant install images (object store is SeaweedFS — MinIO's public images were
# withdrawn in 2025; see docs/decisions.md).
IMAGES="
docker.io/library/mysql:8.0
docker.io/chrislusf/seaweedfs:3.80
docker.io/amazon/aws-cli:2.27.49
docker.io/prom/mysqld-exporter:v0.15.1
"
# Platform (cage) images.
PLATFORM_IMAGES="
docker.io/mitmproxy/mitmproxy:latest
docker.io/library/registry:2
"

load() {  # $1 = image ref to pull+load
  echo "==> pull $1"
  if docker pull -q "$1"; then
    echo "==> load $1 into kind"
    kind load docker-image "$1" --name halden
  else
    echo "!! FAILED to pull $1"
  fi
}

for img in $IMAGES $PLATFORM_IMAGES; do load "$img"; done

# cap-web: pull :latest, retag to the pinned tag the profile expects, load the tag.
echo "==> pull ghcr.io/capsoftware/cap-web:latest and retag -> :$CAPWEB_TAG"
if docker pull -q ghcr.io/capsoftware/cap-web:latest; then
  docker tag ghcr.io/capsoftware/cap-web:latest "ghcr.io/capsoftware/cap-web:$CAPWEB_TAG"
  kind load docker-image "ghcr.io/capsoftware/cap-web:$CAPWEB_TAG" --name halden
else
  echo "!! FAILED to pull cap-web"
fi

echo "ALL DONE"
