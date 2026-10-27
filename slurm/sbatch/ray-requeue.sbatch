#!/bin/bash
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=2
#SBATCH --time=00:30:00
#SBATCH --output=/data/logs/%x-%j.out
#SBATCH --open-mode=append
#SBATCH --requeue
#SBATCH --signal=B:USR1@60
#
# ray-symmetric.sbatch plus preemption handling: Slurm sends USR1 to this batch shell 60 s before the
# time limit (or `scancel --batch --signal=USR1` does, in drill D2), and the trap requeues the job.
# RUN is fixed at submission, so the restarted job resumes from the latest checkpoint (FR-12).
# The log is opened in append mode, so it keeps every attempt.
set -euo pipefail
source /opt/rayslurm/slurm/sbatch/lib.sh
export RAY_SYMMETRIC_RUN_CLUSTER_WAIT_TIMEOUT=120

on_usr1() {
  echo "requeue: USR1 at $(date +%s.%N), restart=${SLURM_RESTART_COUNT:-0}; scontrol requeue $SLURM_JOB_ID"
  scontrol requeue "$SLURM_JOB_ID"
}
trap on_usr1 USR1

# In the background, so bash can run the trap while the step is still going.
srun --nodes=2 --ntasks=2 --ntasks-per-node=1 --cpus-per-task="$SLURM_CPUS_PER_TASK" \
  ray symmetric-run --address "$head_ip:6379" --min-nodes 2 \
    --num-cpus="$SLURM_CPUS_PER_TASK" --num-gpus=0 \
  -- "${train_cmd[@]}" &
step=$!
# A trapped signal makes `wait` return early; keep waiting until the step itself has ended.
rc=0
while true; do
  wait "$step" && rc=0 || rc=$?
  kill -0 "$step" 2>/dev/null || break
done
exit "$rc"
