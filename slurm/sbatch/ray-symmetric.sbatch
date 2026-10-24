#!/bin/bash
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=2
#SBATCH --time=00:30:00
#SBATCH --output=/data/logs/%x-%j.out
#
# Ray on Slurm with `ray symmetric-run` (Ray >= 2.49): one srun task per node starts Ray on that node,
# and the entrypoint (train.py) runs only on the head. Parameters arrive through `sbatch --export`
# (scripts/train-slurm.sh). Single-tenant: symmetric-run does not support multi-tenant port layouts.
set -euo pipefail
: "${RUN:?}" "${EPOCHS:?}" "${WORKERS:?}" "${DATA:?}" "${SAMPLES:?}"
export PATH=/opt/venv/bin:$PATH
export RAY_TRAIN_V2_ENABLED=1
# symmetric-run waits this long for the head / all nodes (default 30 s).
export RAY_SYMMETRIC_RUN_CLUSTER_WAIT_TIMEOUT=120

# Head address, Ray Slurm docs pattern: first node of the allocation, IP read on that node.
head_node=$(scontrol show hostnames "$SLURM_JOB_NODELIST" | head -n 1)
head_ip=$(srun --nodes=1 --ntasks=1 -w "$head_node" hostname --ip-address 2>/dev/null | awk '{print $1}') || head_ip=""
if [[ ! "$head_ip" =~ ^[0-9]+(\.[0-9]+){3}$ || "$head_ip" == 127.* ]]; then
  # The upstream entrypoint renames compute containers to c1, c2 after start; that name may not resolve.
  echo "GOTCHA: 'hostname --ip-address' on $head_node returned '${head_ip}'; falling back to 'hostname -I'"
  head_ip=$(srun --nodes=1 --ntasks=1 -w "$head_node" hostname -I | awk '{print $1}')
fi
echo "job=$SLURM_JOB_ID run=$RUN nodes=$SLURM_JOB_NODELIST head_node=$head_node head_ip=$head_ip"

srun --nodes=2 --ntasks=2 --ntasks-per-node=1 --cpus-per-task="$SLURM_CPUS_PER_TASK" \
  ray symmetric-run --address "$head_ip:6379" --min-nodes 2 \
    --num-cpus="$SLURM_CPUS_PER_TASK" --num-gpus=0 \
  -- python -u /opt/rayslurm/train/train.py --run-name "$RUN" --epochs "$EPOCHS" \
    --workers "$WORKERS" --data "$DATA" --synthetic-samples "$SAMPLES"
