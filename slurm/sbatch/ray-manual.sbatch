#!/bin/bash
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=2
#SBATCH --time=00:30:00
#SBATCH --output=/data/logs/%x-%j.out
#
# Ray on Slurm, started by hand so that two jobs can share nodes: the head with `srun -w <head>`,
# the workers with `srun --exclude <head>`, every Ray port taken from a per-job block (SPEC §8.5) and
# a per-job --temp-dir. The driver runs in this batch shell with RAY_ADDRESS pointing at this job's
# head, so it never attaches to another job's cluster. base+3 (--ray-client-server-port) stays unused:
# the image has ray[train] without ray[client], so Ray starts no client server, and setting the port fails.
set -euo pipefail
source /opt/rayslurm/slurm/sbatch/lib.sh

base=$(( 10000 + (SLURM_JOB_ID % 22) * 1000 ))
temp_dir=/tmp/ray-$SLURM_JOB_ID
node_opts=(
  --node-manager-port=$((base + 1)) --object-manager-port=$((base + 2))
  --dashboard-agent-grpc-port=$((base + 5)) --dashboard-agent-listen-port=$((base + 6))
  --metrics-export-port=$((base + 7)) --runtime-env-agent-port=$((base + 8))
  --min-worker-port=$((base + 100)) --max-worker-port=$((base + 999))
  --temp-dir="$temp_dir" --num-cpus="$SLURM_CPUS_PER_TASK" --num-gpus=0
  --disable-usage-stats --block
)
echo "ray-manual port map: gcs=$base node_manager=$((base + 1)) object_manager=$((base + 2))" \
  "client_server=off dashboard=$((base + 4)) agent_grpc=$((base + 5))" \
  "agent_listen=$((base + 6)) metrics=$((base + 7)) runtime_env_agent=$((base + 8))" \
  "worker_ports=$((base + 100))-$((base + 999)) temp_dir=$temp_dir"

pids=()
# `ray stop` is node-wide (it would also stop another job's Ray), so cleanup ends only our own steps.
cleanup() { kill "${pids[@]}" 2>/dev/null || true; wait 2>/dev/null || true; }
trap cleanup EXIT

srun --nodes=1 --ntasks=1 -w "$head_node" \
  ray start --head --node-ip-address="$head_ip" --port="$base" --dashboard-port=$((base + 4)) "${node_opts[@]}" &
pids+=($!)
srun --nodes=$((SLURM_JOB_NUM_NODES - 1)) --ntasks=$((SLURM_JOB_NUM_NODES - 1)) --exclude="$head_node" \
  ray start --address="$head_ip:$base" "${node_opts[@]}" &
pids+=($!)

export RAY_ADDRESS="$head_ip:$base"
# Wait until every node of the allocation has joined (the same 120 s budget as symmetric-run).
python - "$SLURM_JOB_NUM_NODES" <<'PY'
import sys, time
import ray
want, deadline = int(sys.argv[1]), time.monotonic() + 120
while True:
    try:
        ray.init(logging_level="ERROR")
        break
    except Exception:
        if time.monotonic() > deadline:
            sys.exit("ray-manual: head did not come up within 120 s")
        time.sleep(2)
while (alive := sum(n["Alive"] for n in ray.nodes())) < want:
    if time.monotonic() > deadline:
        sys.exit(f"ray-manual: {alive}/{want} nodes joined within 120 s")
    time.sleep(2)
print(f"ray-manual: {alive} nodes up at {ray.get_runtime_context().gcs_address}")
PY
"${train_cmd[@]}"
