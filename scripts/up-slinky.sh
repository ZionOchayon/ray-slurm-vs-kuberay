#!/usr/bin/env bash
# `make up-slinky` (SPEC FR-40): in the kind cluster rayk8s, install SchedMD's slurm-operator, MariaDB for
# accounting and a Slurm cluster (the `slurm` chart) whose slurmd pods run the rayslinky image; return when
# partition cpu has 2 idle nodes. Idempotent: a second run restarts the slurmd pods only if the image changed.
# Exit: 0 ready, 1 tool or install failure, 124 nodes not idle in time.
set -euo pipefail
: "${SLINKY_VERSION:?}" "${RAY_VERSION:?}" "${SLURM_VERSION:?}" "${MARIADB_IMAGE:?}" "${ALPINE_IMAGE:?}"
CTX=kind-rayk8s
CHARTS=oci://ghcr.io/slinkyproject/charts
IMAGE=rayslinky:$RAY_VERSION-$SLURM_VERSION
k() { kubectl --context "$CTX" "$@"; }

for tool in kind kubectl helm; do
  command -v "$tool" >/dev/null || { echo "up-slinky: $tool not found (see README prerequisites)" >&2; exit 1; }
done
bash scripts/kind-cluster.sh

echo "up-slinky: slurm-operator $SLINKY_VERSION"
helm --kube-context "$CTX" upgrade --install slurm-operator-crds "$CHARTS/slurm-operator-crds" \
  --version "$SLINKY_VERSION" --wait
helm --kube-context "$CTX" upgrade --install slurm-operator "$CHARTS/slurm-operator" \
  --version "$SLINKY_VERSION" --namespace slinky --create-namespace \
  --set certManager.enabled=false --wait --timeout 5m

echo "up-slinky: building $IMAGE"
old_id=$(docker image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null || true)
docker build -q -t "$IMAGE" -f slinky/Dockerfile --build-arg UV_IMAGE --build-arg SLINKY_SLURMD_IMAGE \
  --build-arg RAY_VERSION --build-arg TORCH_VERSION --build-arg TORCHVISION_VERSION \
  --build-arg SLINKY_PYTHON_VERSION .
kind load docker-image "$IMAGE" --name rayk8s

k create namespace slurm --dry-run=client -o yaml | k apply -f - >/dev/null
sed "s|__MARIADB_IMAGE__|$MARIADB_IMAGE|" k8s/slinky-mariadb.yaml | k apply -f -
k -n slurm rollout status deploy/mariadb --timeout=300s

# repo:tag@sha256:… → the chart's {repository, tag, digest}.
values=.data/slinky-values.yaml
cp k8s/slinky-values.yaml "$values"
for pair in SLURMCTLD:SLINKY_SLURMCTLD_IMAGE SLURMDBD:SLINKY_SLURMDBD_IMAGE SLURMRESTD:SLINKY_SLURMRESTD_IMAGE \
  LOGIN:SLINKY_LOGIN_IMAGE ALPINE:ALPINE_IMAGE; do
  key=${pair%%:*} var=${pair#*:}
  ref=${!var}
  [[ "$ref" == *@sha256:* ]] || { echo "up-slinky: $var must be pinned by digest" >&2; exit 1; }
  name=${ref%@*}
  sed -i -e "s|__${key}_REPO__|${name%:*}|" -e "s|__${key}_TAG__|${name##*:}|" -e "s|__${key}_DIGEST__|${ref#*@}|" "$values"
done
sed -i "s|__RAYSLINKY_TAG__|$RAY_VERSION-$SLURM_VERSION|" "$values"
if grep -q '__[A-Z_]*__' "$values"; then echo "up-slinky: unfilled placeholder in $values" >&2; exit 1; fi

echo "up-slinky: slurm chart $SLINKY_VERSION"
helm --kube-context "$CTX" upgrade --install slurm "$CHARTS/slurm" --version "$SLINKY_VERSION" \
  --namespace slurm -f "$values" --wait --timeout 10m
# A rebuilt image with the same tag needs new slurmd pods; an unchanged one must not restart them: the
# operator's preStop hook marks a terminating pod's node DOWN, and it stays DOWN after the pod returns.
new_id=$(docker image inspect -f '{{.Id}}' "$IMAGE")
if [[ -n "$old_id" && "$old_id" != "$new_id" ]]; then
  echo "up-slinky: image changed; restarting slurmd pods"
  k -n slurm delete pods -l app.kubernetes.io/name=slurmd --wait=true >/dev/null 2>&1 || true
fi

sx() { bash scripts/slinky-exec.sh "$@" < /dev/null; }
for _ in $(seq 60); do
  if [[ "$(sx sinfo -h -p cpu -t idle -o %D 2>/dev/null)" == "2" ]]; then
    sx sinfo
    exit 0
  fi
  # Nodes left DOWN by a pod restart come back once their slurmd pods run again.
  if [[ "$(k -n slurm get pods -l app.kubernetes.io/name=slurmd --field-selector=status.phase=Running -o name 2>/dev/null | wc -l)" == 2 ]]; then
    down=$(sx sinfo -h -p cpu -t down,drain -o %N 2>/dev/null || true)
    [[ -n "$down" ]] && sx scontrol update nodename="$down" state=resume 2>/dev/null || true
  fi
  sleep 5
done
sx sinfo -R >&2 || true
k -n slurm get pods -o wide >&2 || true
echo "up-slinky: 2 idle nodes in partition cpu not reached within 300 s" >&2
exit 124
