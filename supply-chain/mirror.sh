#!/usr/bin/env bash
# =============================================================================
# Private registry handling process — run on a BASTION with temporary egress
# (the only place that ever needs the install-time allowlist). For each image:
#   pull -> retag to the private registry -> push -> cosign SIGN (by digest) ->
#   SBOM (syft) -> cosign VERIFY.
#
# The customer then verifies our images WITHOUT trusting us:
#   cosign verify --key supply-chain/cosign.pub <REGISTRY>/<name>@<digest>
#
# Env:
#   REGISTRY     destination registry prefix (e.g. registry.halden.internal/cap)
#   COSIGN_KEY   path to cosign private key (default supply-chain/cosign.key)
#   COSIGN_PASSWORD  password for the key (export "" for CI)
#   CAP_SRC      path to a Cap source checkout (for building media-server)
# =============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="${REGISTRY:?set REGISTRY, e.g. registry.halden.internal/cap or localhost:5050/cap}"
COSIGN_KEY="${COSIGN_KEY:-$ROOT/supply-chain/cosign.key}"
SBOM_DIR="${SBOM_DIR:-$ROOT/supply-chain/sbom}"
IMAGES_YAML="$ROOT/supply-chain/images.yaml"
mkdir -p "$SBOM_DIR"

sign_and_sbom() {  # $1 = full ref with tag
  local ref="$1" name="$2"
  docker push "$ref"
  local digest; digest="$(docker inspect --format '{{index .RepoDigests 0}}' "$ref" | cut -d@ -f2)"
  local bydigest="${ref%:*}@${digest}"
  echo "   signing $bydigest (offline; no transparency log — air-gap safe)"
  cosign sign ${COSIGN_FLAGS:-} --tlog-upload=false --key "$COSIGN_KEY" --yes "$bydigest"
  echo "   sbom -> $SBOM_DIR/$name.spdx.json"
  # Scan the local image via the docker daemon (avoids registry TLS quirks).
  syft "docker:$ref" -o spdx-json > "$SBOM_DIR/$name.spdx.json" 2>/dev/null || echo "   (syft skipped)"
  echo "   verifying"
  cosign verify ${COSIGN_FLAGS:-} --insecure-ignore-tlog=true --key "$ROOT/supply-chain/cosign.pub" "$bydigest" >/dev/null
  echo "   OK $name -> $bydigest"
}

echo "== mirroring images to $REGISTRY =="
count=$(yq '.images | length' "$IMAGES_YAML")
for i in $(seq 0 $((count-1))); do
  src=$(yq -r ".images[$i].source" "$IMAGES_YAML")
  name=$(yq -r ".images[$i].name" "$IMAGES_YAML")
  repo=$(yq -r ".images[$i].repository" "$IMAGES_YAML")
  tag=$(yq -r ".images[$i].tag" "$IMAGES_YAML")
  # Keep the chart's repository path so $REGISTRY/<repo>:<tag> == the chart's ref
  # under --set global.imageRegistry=$REGISTRY.
  dst="$REGISTRY/$repo:$tag"
  echo "-> $name ($src -> $dst)"
  docker pull "$src"
  docker tag "$src" "$dst"
  sign_and_sbom "$dst" "$name"
done

# Build media-server from Cap source (needs egress for apt/bun).
if [ -n "${CAP_SRC:-}" ] && [ -d "$CAP_SRC" ]; then
  bname=$(yq -r '.build[0].name' "$IMAGES_YAML")
  brepo=$(yq -r '.build[0].repository' "$IMAGES_YAML")
  btag=$(yq -r '.build[0].tag' "$IMAGES_YAML")
  bfile=$(yq -r '.build[0].dockerfile' "$IMAGES_YAML")
  bctx=$(yq -r '.build[0].context' "$IMAGES_YAML")
  dst="$REGISTRY/$brepo:$btag"
  echo "-> building $bname from $CAP_SRC"
  docker build --network=host -f "$CAP_SRC/$bfile" -t "$dst" "$CAP_SRC/$bctx"
  sign_and_sbom "$dst" "$bname"
else
  echo "!! CAP_SRC not set — skipping media-server build (set CAP_SRC=/path/to/Cap)"
fi

echo "== done. Point the install at the registry with: --set global.imageRegistry=$REGISTRY =="
