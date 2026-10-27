# shellcheck shell=bash
# Shared by ray-manual.sbatch and ray-requeue.sbatch (sourced from the read-only repo mount).
# Sets head_node, head_ip and the train.py command line in train_cmd.
: "${RUN:?}" "${EPOCHS:?}" "${WORKERS:?}" "${DATA:?}" "${SAMPLES:?}"
export PATH=/opt/venv/bin:$PATH
export RAY_TRAIN_V2_ENABLED=1

# Head address, Ray Slurm docs pattern: first node of the allocation, IP read on that node.
head_node=$(scontrol show hostnames "$SLURM_JOB_NODELIST" | head -n 1)
head_ip=$(srun --nodes=1 --ntasks=1 -w "$head_node" hostname --ip-address 2>/dev/null | awk '{print $1}') || head_ip=""
if [[ ! "$head_ip" =~ ^[0-9]+(\.[0-9]+){3}$ || "$head_ip" == 127.* ]]; then
  echo "GOTCHA: 'hostname --ip-address' on $head_node returned '${head_ip}'; falling back to 'hostname -I'"
  head_ip=$(srun --nodes=1 --ntasks=1 -w "$head_node" hostname -I | awk '{print $1}')
fi
echo "job=$SLURM_JOB_ID run=$RUN restart=${SLURM_RESTART_COUNT:-0} nodes=$SLURM_JOB_NODELIST head_node=$head_node head_ip=$head_ip"

train_cmd=(python -u /opt/rayslurm/train/train.py --run-name "$RUN" --epochs "$EPOCHS"
  --workers "$WORKERS" --data "$DATA" --synthetic-samples "$SAMPLES")
