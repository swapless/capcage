#!/usr/bin/env bash
# Pull base images on the host (which has egress) and load them into the kind
# nodes' containerd (which does not). Mirrors the air-gap mirror.sh pattern.
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"
IMAGES="
docker.io/library/mysql:8.0
docker.io/minio/minio:RELEASE.2024-10-13T13-34-11Z
docker.io/minio/mc:RELEASE.2024-10-08T09-37-31Z
docker.io/prom/mysqld-exporter:v0.15.1
ghcr.io/capsoftware/cap-web:latest
"
for img in $IMAGES; do
  echo "==> pull $img"
  if docker pull -q "$img"; then
    echo "==> load $img into kind"
    kind load docker-image "$img" --name halden
  else
    echo "!! FAILED to pull $img"
  fi
done
echo "ALL DONE"
