#!/usr/bin/env bash
# M1 (SPEC §10): wall time from submission to the first completed optimizer step, warm (cluster up,
# images cached), REPS_M1 fresh runs with EPOCHS=1. The submit timestamp is taken inside the VM right
# before sbatch / kubectl apply; the end is first_step (restart_count 0) from events.jsonl.
# Exit: 0 every rep measured, 1 otherwise.
set -euo pipefail
source drills/lib.sh
: "${REPS_M1:?}"

csv_open m1
k8s_setup
failed=0
for rep in $(seq "$REPS_M1"); do
  run="m1-$SCHED-$(date -u +%H%M%S)-$rep"
  DRILL_EPOCHS=1 DRILL_SAMPLES=8192 start_train "$run"
  rc=0
  wait "$TRAIN_PID" || rc=$?
  if [[ $SCHED == slurm ]]; then
    submit_ts=$(docker exec slurmctld tail -n 1 "/data/logs/$run.submit_ts")
  else
    submit_ts=$(tail -n 1 ".data/k8s/logs/$run.submit_ts")
  fi
  out=$(analyze m1 "$run" --submit-ts "$submit_ts" || true)
  echo "M1 $SCHED rep $rep ($run, exit $rc): $(tr '\n' ' ' <<< "$out")"
  v=$(kv submit_to_first_step_s <<< "$out")
  if (( rc != 0 )) || [[ -z "$v" ]]; then
    failed=1
    csv_row M1_submit_to_first_step_s warm "$rep" NA s "$run"
    continue
  fi
  csv_row M1_submit_to_first_step_s warm "$rep" "$v" s "$run"
  csv_row M1_submit_to_driver_start_s warm "$rep" "$(kv submit_to_driver_start_s <<< "$out")" s "$run"
  csv_row M1_driver_start_to_first_step_s warm "$rep" "$(kv driver_start_to_first_step_s <<< "$out")" s "$run"
done
exit "$failed"
