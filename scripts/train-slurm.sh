#!/usr/bin/env bash
# `make train-slurm`: submit slurm/sbatch/ray-<LAUNCHER>.sbatch, block until the job ends, report.
# Exit: 0 job COMPLETED, 1 any other final state, 2 invalid input, 124 timeout (job cancelled).
set -euo pipefail

RUN_RE='^[a-z0-9]([a-z0-9-]{0,40}[a-z0-9])?$'
[[ "${RUN:-}" =~ $RUN_RE ]] || { echo "train-slurm: invalid RUN '${RUN:-}' (must match $RUN_RE)" >&2; exit 2; }
for v in EPOCHS WORKERS SAMPLES TIMEOUT; do
  [[ "${!v:-}" =~ ^[1-9][0-9]*$ ]] || { echo "train-slurm: $v must be a positive integer" >&2; exit 2; }
done
# DATA is only shape-checked (it goes into --export); train.py decides whether the value is valid.
[[ "${DATA:-}" =~ ^[a-z0-9-]+$ ]] || { echo "train-slurm: invalid DATA '${DATA:-}'" >&2; exit 2; }
LAUNCHER=${LAUNCHER:-symmetric} EXCLUSIVE=${EXCLUSIVE:-0} MEM_PER_NODE=${MEM_PER_NODE:-2G}
[[ "$LAUNCHER" =~ ^(symmetric|manual|requeue)$ ]] || { echo "train-slurm: LAUNCHER must be symmetric, manual or requeue" >&2; exit 2; }
[[ "$EXCLUSIVE" =~ ^[01]$ ]] || { echo "train-slurm: EXCLUSIVE must be 0 or 1" >&2; exit 2; }
[[ "$MEM_PER_NODE" =~ ^[1-9][0-9]*[MG]$ ]] || { echo "train-slurm: MEM_PER_NODE must look like 2G or 512M" >&2; exit 2; }
# Upstream's slurm.conf uses CR_Core_Memory with no default, so a job without --mem is given all of
# each node's memory and no second job can ever share the nodes (docs/NOTES.md 2026-10-27). Memory is
# not enforced (ConstrainRAMSpace=no); --mem only lets the scheduler pack jobs.
extra=(--mem="$MEM_PER_NODE")
(( EXCLUSIVE )) && extra+=(--exclusive)

docker exec slurmctld sinfo >/dev/null 2>&1 || { echo "cluster not up: run make up" >&2; exit 1; }

echo "train-slurm: RUN=$RUN EPOCHS=$EPOCHS WORKERS=$WORKERS DATA=$DATA SAMPLES=$SAMPLES" \
  "LAUNCHER=$LAUNCHER EXCLUSIVE=$EXCLUSIVE MEM_PER_NODE=$MEM_PER_NODE TIMEOUT=${TIMEOUT}s"
mkdir -p .runs
echo "$LAUNCHER" > ".runs/$RUN.launcher"
rc=0
# The submit timestamp (M1) is taken in slurmctld right before sbatch, on the clock the job uses.
timeout "$TIMEOUT" docker exec slurmctld bash -c 'date +%s.%N >> "/data/logs/$1.submit_ts"; shift; exec sbatch "$@"' _ \
  "$RUN" --parsable --wait --job-name="$RUN" "${extra[@]}" \
  --export="ALL,RUN=$RUN,EPOCHS=$EPOCHS,WORKERS=$WORKERS,DATA=$DATA,SAMPLES=$SAMPLES" \
  "/opt/rayslurm/slurm/sbatch/ray-$LAUNCHER.sbatch" || rc=$?
if (( rc == 124 )); then
  docker exec slurmctld scancel --name="$RUN" || true
fi

# Accounting (slurmdbd) can lag the controller by a few seconds.
jobid="" state=""
for _ in $(seq 15); do
  jobid=$(docker exec slurmctld sacct -n -X -P -S now-7days --name="$RUN" -o JobID | tail -n 1)
  if [[ -n "$jobid" ]]; then
    state=$(docker exec slurmctld sacct -n -X -P -j "$jobid" -o State,ExitCode,Elapsed)
    [[ "${state%%|*}" =~ ^(PENDING|RUNNING|COMPLETING|REQUEUED)$ ]] || break
  fi
  sleep 2
done
if [[ -z "$jobid" ]]; then
  echo "train-slurm: no job named $RUN found in sacct (sbatch exit $rc)" >&2
  exit 1
fi

echo "$jobid" > ".runs/$RUN.jobid"
echo "$RUN" > .runs/latest
log="/data/logs/$RUN-$jobid.out"
echo
echo "job $jobid  State|ExitCode|Elapsed: $state"
echo "log: $log (last 40 lines)"
docker exec slurmctld tail -n 40 "$log" || true

if (( rc == 124 )); then
  echo "train-slurm: timed out after ${TIMEOUT}s; job cancelled" >&2
  exit 124
fi
if [[ "${state%%|*}" != COMPLETED ]]; then
  echo "train-slurm: job $jobid ended ${state%%|*}" >&2
  exit 1
fi
