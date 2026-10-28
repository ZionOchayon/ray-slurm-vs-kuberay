#!/usr/bin/env bash
# Create the one-node kind cluster `rayk8s` (host .data/k8s mounted at the node's /data) if it is absent.
# Shared by make train-k8s (KubeRay) and make up-slinky (Slinky), which run in the same cluster.
set -euo pipefail
: "${KIND_NODE_IMAGE:?}"
# Created by the host user first, so the host can write logs next to what the pods (root) write.
mkdir -p .data/k8s/logs .data/k8s/ray_results .runs
if ! kind get clusters 2>/dev/null | grep -qx rayk8s; then
  echo "kind: creating cluster rayk8s ($KIND_NODE_IMAGE)"
  sed "s|__DATA_DIR__|$PWD/.data/k8s|" k8s/kind-config.yaml > .data/kind-config.yaml
  kind create cluster --name rayk8s --image "$KIND_NODE_IMAGE" --config .data/kind-config.yaml --wait 180s
fi
