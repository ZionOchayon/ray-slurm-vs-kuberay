#!/usr/bin/env bash
# `make train-k8s`: kind cluster + KubeRay operator (if absent), build and load the image, apply the
# RayJob, block until it ends, report. The K8s counterpart of scripts/train-slurm.sh.
# Exit: 0 RayJob SUCCEEDED, 1 any other final state or environment problem, 2 invalid input,
# 124 timeout (RayJob deleted).
set -euo pipefail

RUN_RE='^[a-z0-9]([a-z0-9-]{0,40}[a-z0-9])?$'
[[ "${RUN:-}" =~ $RUN_RE ]] || { echo "train-k8s: invalid RUN '${RUN:-}' (must match $RUN_RE)" >&2; exit 2; }
for v in EPOCHS WORKERS SAMPLES K8S_TIMEOUT; do
  [[ "${!v:-}" =~ ^[1-9][0-9]*$ ]] || { echo "train-k8s: $v must be a positive integer" >&2; exit 2; }
done
[[ "${DATA:-}" =~ ^[a-z0-9-]+$ ]] || { echo "train-k8s: invalid DATA '${DATA:-}'" >&2; exit 2; }
BACKOFF_LIMIT=${BACKOFF_LIMIT:-0} K8S_CPU_REQUEST=${K8S_CPU_REQUEST:-2}
# K8S_SETUP: 1 = set up (cluster, operator, image) and run; 0 = run only; only = set up and exit.
# Drills set up once and then start runs in parallel with 0.
K8S_SETUP=${K8S_SETUP:-1}
[[ "$K8S_SETUP" =~ ^(0|1|only)$ ]] || { echo "train-k8s: K8S_SETUP must be 0, 1 or only" >&2; exit 2; }
[[ "$BACKOFF_LIMIT" =~ ^[0-9]+$ ]] || { echo "train-k8s: BACKOFF_LIMIT must be an integer >= 0" >&2; exit 2; }
[[ "$K8S_CPU_REQUEST" =~ ^[0-9]+(m|\.[0-9]+)?$ ]] || { echo "train-k8s: invalid K8S_CPU_REQUEST" >&2; exit 2; }
: "${KIND_NODE_IMAGE:?}" "${KUBERAY_VERSION:?}" "${RAY_IMAGE:?}" "${RAY_VERSION:?}"

CLUSTER=rayk8s
NODE=$CLUSTER-control-plane
CTX=kind-$CLUSTER
IMAGE=rayk8s:$RAY_VERSION
k() { kubectl --context "$CTX" "$@"; }

for tool in kind kubectl helm; do
  command -v "$tool" >/dev/null || { echo "train-k8s: $tool not found (see README prerequisites)" >&2; exit 1; }
done
docker info >/dev/null 2>&1 || { echo "train-k8s: docker engine unreachable" >&2; exit 1; }

mkdir -p .data/k8s/logs .data/k8s/ray_results .runs
if [[ "$K8S_SETUP" != 0 ]]; then
  bash scripts/kind-cluster.sh

  if ! helm --kube-context "$CTX" status kuberay-operator -n kuberay-system >/dev/null 2>&1; then
    echo "train-k8s: installing the KubeRay operator chart $KUBERAY_VERSION"
    helm --kube-context "$CTX" upgrade --install kuberay-operator kuberay-operator \
      --repo https://ray-project.github.io/kuberay-helm/ --version "$KUBERAY_VERSION" \
      --namespace kuberay-system --create-namespace --wait --timeout 5m
  fi

  echo "train-k8s: building $IMAGE"
  docker build -q -t "$IMAGE" -f k8s/Dockerfile \
    --build-arg RAY_IMAGE --build-arg RAY_VERSION --build-arg TORCH_VERSION --build-arg TORCHVISION_VERSION .
  kind load docker-image "$IMAGE" --name "$CLUSTER"
fi
[[ "$K8S_SETUP" == only ]] && exit 0

# The same RUN again (resume, FR-12) needs the finished RayJob of that name out of the way first.
k delete rayjob "$RUN" --ignore-not-found --wait=true >/dev/null
sed -e "s|__RUN__|$RUN|g" -e "s|__EPOCHS__|$EPOCHS|g" -e "s|__WORKERS__|$WORKERS|g" \
  -e "s|__DATA__|$DATA|g" -e "s|__SAMPLES__|$SAMPLES|g" -e "s|__BACKOFF_LIMIT__|$BACKOFF_LIMIT|g" \
  -e "s|__RAY_VERSION__|$RAY_VERSION|g" -e "s|__CPU_REQUEST__|$K8S_CPU_REQUEST|g" \
  k8s/rayjob.yaml > ".data/rayjob-$RUN.yaml"

echo "train-k8s: RUN=$RUN EPOCHS=$EPOCHS WORKERS=$WORKERS DATA=$DATA SAMPLES=$SAMPLES" \
  "BACKOFF_LIMIT=$BACKOFF_LIMIT K8S_CPU_REQUEST=$K8S_CPU_REQUEST K8S_TIMEOUT=${K8S_TIMEOUT}s"
# Submit from inside the kind node, so the submit timestamp (M1) uses the same clock as the pods.
docker exec -i "$NODE" sh -c "date +%s.%N >> /data/logs/$RUN.submit_ts &&
  kubectl --kubeconfig /etc/kubernetes/admin.conf apply -f -" < ".data/rayjob-$RUN.yaml"
echo "$RUN" > .runs/latest
echo "k8s" > ".runs/$RUN.launcher"

status="" deploy="" start=$SECONDS
while (( SECONDS - start < K8S_TIMEOUT )); do
  status=$(k get rayjob "$RUN" -o jsonpath='{.status.jobStatus}' 2>/dev/null || true)
  deploy=$(k get rayjob "$RUN" -o jsonpath='{.status.jobDeploymentStatus}' 2>/dev/null || true)
  # jobDeploymentStatus Complete/Failed is final; jobStatus alone can read FAILED between retries.
  [[ "$deploy" =~ ^(Complete|Failed)$ ]] && break
  sleep 5
done

log=".data/k8s/logs/$RUN.out"
k logs "job/$RUN" --all-containers --tail=-1 > "$log" 2>&1 || true
echo "${status:-UNKNOWN}" > ".runs/$RUN.k8s"
echo
echo "rayjob $RUN  jobStatus=${status:-?} jobDeploymentStatus=${deploy:-?} waited=$(( SECONDS - start ))s"
echo "log: $log (last 40 lines)"
tail -n 40 "$log" || true

if [[ ! "$deploy" =~ ^(Complete|Failed)$ || "$status" != SUCCEEDED ]]; then
  k get pods -o wide || true
  k get events --sort-by=.lastTimestamp | tail -n 20 || true
fi
if [[ ! "$deploy" =~ ^(Complete|Failed)$ ]]; then
  k delete rayjob "$RUN" --ignore-not-found --wait=false || true
  echo "train-k8s: timed out after ${K8S_TIMEOUT}s; RayJob deleted" >&2
  exit 124
fi
if [[ "$status" != SUCCEEDED ]]; then
  echo "train-k8s: RayJob $RUN ended $status ($deploy)" >&2
  exit 1
fi
