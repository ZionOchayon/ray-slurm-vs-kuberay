#!/usr/bin/env bash
# `make train-slurm` / `make train-slinky`: submit slurm/sbatch/ray-<LAUNCHER>.sbatch, block until the job
# ends, report. SCHED=slurm runs Slurm commands in the Compose slurmctld container; SCHED=slinky runs them
# in Slinky's login pod and feeds the same sbatch file on stdin (the slurmd image has /opt/rayslurm baked in).
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

SCHED=${SCHED:-slurm}
script=slurm/sbatch/ray-$LAUNCHER.sbatch
case $SCHED in
  slurm) sx=(docker exec -i slurmctld) up_cmd="make up" script_arg=("/opt/rayslurm/$script") ;;
  slinky) sx=(bash scripts/slinky-exec.sh) up_cmd="make up-slinky" script_arg=() ;;
  *) echo "train-slurm: SCHED must be slurm or slinky" >&2; exit 2 ;;
esac
"${sx[@]}" sinfo >/dev/null 2>&1 < /dev/null || { echo "cluster not up: run $up_cmd" >&2; exit 1; }

echo "train-$SCHED: RUN=$RUN EPOCHS=$EPOCHS WORKERS=$WORKERS DATA=$DATA SAMPLES=$SAMPLES" \
  "LAUNCHER=$LAUNCHER EXCLUSIVE=$EXCLUSIVE MEM_PER_NODE=$MEM_PER_NODE TIMEOUT=${TIMEOUT}s"
mkdir -p .runs
echo "$LAUNCHER" > ".runs/$RUN.launcher"
echo "$SCHED" > ".runs/$RUN.sched"
rc=0
# The submit timestamp (M1) is taken right before sbatch, inside the cluster, on the clock the job uses.
# With no script argument (Slinky), sbatch reads the script from stdin. The job's parameters go into
# sbatch's own environment with a plain --export=ALL: any other --export value (e.g. ALL,RUN=…) makes
# sbatch set SLURM_GET_USER_ENV=1, and Slinky's slurmd failed to load root's login environment.
timeout "$TIMEOUT" "${sx[@]}" env RUN="$RUN" EPOCHS="$EPOCHS" WORKERS="$WORKERS" DATA="$DATA" SAMPLES="$SAMPLES" \
  bash -c 'date +%s.%N >> "/data/logs/$RUN.submit_ts"; exec sbatch "$@"' _ \
  --parsable --wait --job-name="$RUN" "${extra[@]}" --export=ALL "${script_arg[@]}" < "$script" || rc=$?
if (( rc == 124 )); then
  "${sx[@]}" scancel --name="$RUN" < /dev/null || true
fi

# Accounting (slurmdbd) can lag the controller by a few seconds.
jobid="" state=""
for _ in $(seq 15); do
  jobid=$("${sx[@]}" sacct -n -X -P -S now-7days --name="$RUN" -o JobID < /dev/null | tail -n 1)
  if [[ -n "$jobid" ]]; then
    state=$("${sx[@]}" sacct -n -X -P -j "$jobid" -o State,ExitCode,Elapsed < /dev/null)
    [[ "${state%%|*}" =~ ^(PENDING|RUNNING|COMPLETING|REQUEUED)$ ]] || break
  fi
  sleep 2
done
if [[ -z "$jobid" ]]; then
  echo "train-$SCHED: no job named $RUN found in sacct (sbatch exit $rc)" >&2
  exit 1
fi

echo "$jobid" > ".runs/$RUN.jobid"
echo "$RUN" > .runs/latest
log="/data/logs/$RUN-$jobid.out"
echo
echo "job $jobid  State|ExitCode|Elapsed: $state"
echo "log: $log (last 40 lines)"
"${sx[@]}" tail -n 40 "$log" < /dev/null || true

if (( rc == 124 )); then
  echo "train-$SCHED: timed out after ${TIMEOUT}s; job cancelled" >&2
  exit 124
fi
if [[ "${state%%|*}" != COMPLETED ]]; then
  echo "train-$SCHED: job $jobid ended ${state%%|*}" >&2
  exit 1
fi
