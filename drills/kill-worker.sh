#!/usr/bin/env bash
# Drill D1 (SPEC §11, FR-25): kill one Ray Train worker process on the non-head node after the first
# checkpoint. Expected: Ray Train restarts the worker group (max_failures=3), restores the latest
# checkpoint and the job still ends COMPLETED / SUCCEEDED. Records M3 (time_to_resume_s, steps_lost).
# Exit: 0 every rep passed, 1 any rep failed, 2 invalid input.
set -euo pipefail
source drills/lib.sh
: "${REPS:?}"

csv_open drill-kill-worker
sched_setup
failed=0
for rep in $(seq "$REPS"); do
  run="d1-$SCHED-$(date -u +%H%M%S)-$rep"
  echo "== D1 $SCHED rep $rep: $run"
  start_train "$run"
  if ! wait_for 600 ckpt_registered "$run" checkpoint_epoch_000; then
    echo "D1: $run never registered checkpoint_epoch_000" >&2
    wait "$TRAIN_PID" || true
    csv_row D1_outcome default "$rep" fail outcome "$run"
    failed=1
    continue
  fi

  if [[ $SCHED != k8s ]]; then
    job=$(sx squeue -h --name="$run" -o %A)
    batch_host=$(sx squeue -h -j "$job" -o %B)
    other=$(sx bash -c "scontrol show hostnames \$(squeue -h -j $job -o %N)" | grep -vx "$batch_host" | head -n 1)
    ts=$(inject srun --jobid="$job" --overlap -w "$other" pkill -9 -f RayTrainWorker | head -n 1) || true
  else
    pod=$(k8s_pod "$run" worker)
    ts=$(inject exec "$pod" -- pkill -9 -f RayTrainWorker | head -n 1) || true
  fi
  echo "D1: killed RayTrainWorker at $ts"

  rc=0
  wait "$TRAIN_PID" || rc=$?
  out=$(analyze resume "$run" --since "$ts" || true)
  echo "$out"
  verified=0
  verify_run "$run" && verified=1
  restored=$(kv restored_epoch <<< "$out") expected=$(kv expected_epoch <<< "$out")
  t=$(kv time_to_resume_s <<< "$out") lost=$(kv steps_lost <<< "$out")
  csv_row M3_time_to_resume_s default "$rep" "${t:-NA}" s "$run"
  csv_row M3_steps_lost default "$rep" "${lost:-NA}" steps "$run"
  if (( rc == 0 && verified )) && [[ -n "$t" && "$restored" == "$expected" ]]; then
    csv_row D1_outcome default "$rep" pass outcome "$run"
  else
    echo "D1: $run FAILED (exit $rc, verify $verified, restored=$restored expected=$expected)" >&2
    csv_row D1_outcome default "$rep" fail outcome "$run"
    failed=1
  fi
done
echo "D1 $SCHED: $([[ $failed == 0 ]] && echo PASS || echo FAIL) ($CSV)"
exit "$failed"
