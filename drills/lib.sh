# Shared helpers for drills/*.sh and bench/*.sh (sourced). Host side is bash only; anything that
# parses events runs drills/analyze.py inside a container that sees the run's /data.
# Every timestamp comes from inside the Docker VM (slurmctld or the kind node), never the host clock.
: "${SCHED:?SCHED must be slurm or k8s}"
[[ "$SCHED" =~ ^(slurm|k8s)$ ]] || { echo "SCHED must be slurm or k8s" >&2; exit 2; }
: "${RAY_VERSION:?run through make, which loads versions.env}"

K8S_NODE=rayk8s-control-plane
K8S_CTX=kind-rayk8s
RAW_DIR=docs/results/raw
mkdir -p "$RAW_DIR" .runs .data/drills

# Timestamp from the VM clock that also stamps the events.
vm_now() {
  if [[ $SCHED == slurm ]]; then docker exec slurmctld date +%s.%N; else docker exec "$K8S_NODE" date +%s.%N; fi
}

kc() { kubectl --context "$K8S_CTX" "$@"; }

# analyze.py <command> <run> [args]: prints key=value lines.
analyze() {
  local cmd=$1 run=$2
  shift 2
  if [[ $SCHED == slurm ]]; then
    docker exec slurmctld /opt/venv/bin/python /opt/rayslurm/drills/analyze.py "$cmd" \
      --run-dir "/data/ray_results/$run" "$@"
  else
    docker run --rm -v "$PWD/.data/k8s:/data" -v "$PWD:/opt/rayslurm:ro" "rayk8s:$RAY_VERSION" \
      python /opt/rayslurm/drills/analyze.py "$cmd" --run-dir "/data/ray_results/$run" "$@"
  fi
}

# kv <key> <<< "$output": the value of one key=value line.
kv() { sed -n "s/^$1=//p" | head -n 1; }

# True once <run>/<path> exists in the scheduler's /data.
data_exists() {
  if [[ $SCHED == slurm ]]; then docker exec slurmctld test -e "/data/ray_results/$1/$2"; else test -e ".data/k8s/ray_results/$1/$2"; fi
}

# True once Ray Train has registered <checkpoint> (in checkpoint_manager_snapshot.json). A checkpoint
# that is only on disk is not restored after a failure (observed; docs/NOTES.md 2026-10-27).
ckpt_registered() {
  local f="ray_results/$1/checkpoint_manager_snapshot.json"
  if [[ $SCHED == slurm ]]; then docker exec slurmctld grep -q "\"$2\"" "/data/$f"; else grep -q "\"$2\"" ".data/k8s/$f"; fi
}

# wait_for <seconds> <command...>: poll every 0.5 s.
wait_for() {
  local deadline=$((SECONDS + $1))
  shift
  until "$@" 2>/dev/null; do
    ((SECONDS < deadline)) || return 1
    sleep 0.5
  done
}

# start_train <run> [VAR=value...]: start make's training script in the background; sets TRAIN_PID.
# Drill runs default to 4 epochs of 60000 samples, long enough to inject a failure mid-epoch.
start_train() {
  local run=$1
  shift
  local script=scripts/train-slurm.sh
  [[ $SCHED == k8s ]] && script=scripts/train-k8s.sh
  env RUN="$run" EPOCHS="${DRILL_EPOCHS:-4}" WORKERS=2 DATA=synthetic SAMPLES="${DRILL_SAMPLES:-60000}" \
    TIMEOUT="${TIMEOUT:-1200}" K8S_TIMEOUT="${K8S_TIMEOUT:-1200}" K8S_SETUP=0 "$@" \
    bash "$script" > ".data/drills/$run.log" 2>&1 &
  TRAIN_PID=$!
}

# The current K8s head and worker pods of a RayJob's live RayCluster.
k8s_pod() {
  local run=$1 type=$2 cluster
  cluster=$(kc get rayjob "$run" -o jsonpath='{.status.rayClusterName}')
  [[ -n "$cluster" ]] || return 1
  kc get pods -l "ray.io/cluster=$cluster,ray.io/node-type=$type" \
    --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}'
}

# Run a command inside the VM and print the VM timestamp taken just before it.
inject() {
  if [[ $SCHED == slurm ]]; then
    docker exec slurmctld bash -c 'date +%s.%N; "$@" >&2' _ "$@"
  else
    docker exec "$K8S_NODE" sh -c 'date +%s.%N; "$@" >&2' _ \
      kubectl --kubeconfig /etc/kubernetes/admin.conf "$@"
  fi
}

verify_run() {
  make --no-print-directory verify SCHED="$SCHED" RUN="$1" > ".data/drills/$1.verify" 2>&1
}

# One-time K8s setup (cluster, operator, image) before runs that skip it.
k8s_setup() {
  [[ $SCHED == k8s ]] || return 0
  K8S_SETUP=only RUN=setup EPOCHS=1 WORKERS=1 DATA=synthetic SAMPLES=1 K8S_TIMEOUT=1 bash scripts/train-k8s.sh
}

# CSV: metric, scheduler, config, rep, value, unit, run, git_sha, host_profile, date (SPEC §9.5).
host_profile() {
  local model ncpu mem os arch
  model=$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -n 1)
  ncpu=$(docker info --format '{{.NCPU}}')
  mem=$(($(docker info --format '{{.MemTotal}}') / 1024 ** 3))
  os=$(docker info --format '{{.OperatingSystem}}')
  arch=$(docker info --format '{{.Architecture}}')
  echo "${model:-unknown cpu}; ${ncpu} cpu; ${mem} GiB; ${os}; ${arch}" | tr ',"' ';;'
}
GIT_SHA=$(git rev-parse --short HEAD)$(git diff --quiet HEAD -- train scripts drills bench slurm k8s || echo -dirty)
HOST_PROFILE=$(host_profile)

csv_open() {
  CSV="$RAW_DIR/$1-$SCHED-$(date -u +%Y%m%dT%H%M%SZ).csv"
  echo "metric,scheduler,config,rep,value,unit,run,git_sha,host_profile,date" > "$CSV"
  echo "writing $CSV"
}

csv_row() { # metric config rep value unit run
  local value
  value=$(printf '%s' "$4" | tr ',"\n' ';  ')
  echo "$1,$SCHED,$2,$3,$value,$5,$6,$GIT_SHA,$HOST_PROFILE,$(date -u +%FT%TZ)" >> "$CSV"
}
