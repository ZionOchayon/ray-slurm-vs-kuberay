#!/usr/bin/env bash
# Install the pinned kind, kubectl and helm (linux-amd64) into DEST, checking each sha256 from versions.env.
# Used by CI; on a laptop, install the same versions with your package manager instead if you prefer.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source versions.env; set +a
DEST=${DEST:-/usr/local/bin}
[[ "$(uname -s)-$(uname -m)" == Linux-x86_64 ]] || { echo "install-k8s-tools: linux-amd64 only" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl -fsSLo "$tmp/kind" "https://github.com/kubernetes-sigs/kind/releases/download/$KIND_VERSION/kind-linux-amd64"
curl -fsSLo "$tmp/kubectl" "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/amd64/kubectl"
curl -fsSLo "$tmp/helm.tgz" "https://get.helm.sh/helm-$HELM_VERSION-linux-amd64.tar.gz"
sha256sum -c - <<SUMS
$KIND_SHA256_LINUX_AMD64  $tmp/kind
$KUBECTL_SHA256_LINUX_AMD64  $tmp/kubectl
$HELM_SHA256_LINUX_AMD64  $tmp/helm.tgz
SUMS
tar -xzf "$tmp/helm.tgz" -C "$tmp" linux-amd64/helm
install -m 0755 "$tmp/kind" "$tmp/kubectl" "$tmp/linux-amd64/helm" "$DEST/"
kind version && kubectl version --client && helm version --short
