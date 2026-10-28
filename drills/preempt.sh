#!/usr/bin/env bash
# Drill D2 (SPEC §11, FR-24, FR-26): preempt a run after its first registered checkpoint.
#   Slurm, ray-requeue.sbatch: "usr1-trap" sends USR1 to the batch shell (as --signal=B:USR1@60 would)
#   and the trap runs `scontrol requeue`; "admin-requeue" runs `scontrol requeue` directly.
#   K8s: "head-pod-delete" deletes the Ray head pod of a RayJob with backoffLimit 1.
# Expected: the run restarts, resumes from the latest checkpoint (same RUN) and ends COMPLETED /
# SUCCEEDED with restart count >= 1, a restored event, contiguous checkpoints and
# steps_lost <= steps per epoch.
# Exit: 0 every rep passed, 1 any rep failed, 2 invalid input.
set -euo pipefail
source drills/lib.sh
: "${REPS:?}"

if [[ $SCHED != k8s ]]; then configs=(usr1-trap admin-requeue); else configs=(head-pod-delete); fi
# Long enough that work remains after the pod's 30 s termination grace period: with 4 epochs the head
# pod finished the run while terminating (docs/NOTES.md). Same length on both schedulers.
DRILL_EPOCHS=${DRILL_EPOCHS:-10}
csv_open drill-preempt
sched_setup
failed=0
for config in "${configs[@]}"; do
  for rep in $(seq "$REPS"); do
    run="d2-$SCHED-$(date -u +%H%M%S)-$rep"
    echo "== D2 $SCHED $config rep $rep: $run"
    if [[ $SCHED != k8s ]]; then start_train "$run" LAUNCHER=requeue; else start_train "$run" BACKOFF_LIMIT=1; fi
    if ! wait_for 600 ckpt_registered "$run" checkpoint_epoch_000; then
      echo "D2: $run never registered checkpoint_epoch_000" >&2
      wait "$TRAIN_PID" || true
      csv_row D2_outcome "$config" "$rep" fail outcome "$run"
      failed=1
      continue
    fi

    case $config in
      usr1-trap)
        job=$(sx squeue -h --name="$run" -o %A)
        ts=$(inject scancel --batch --signal=USR1 "$job" | head -n 1) ;;
      admin-requeue)
        job=$(sx squeue -h --name="$run" -o %A)
        ts=$(inject scontrol requeue "$job" | head -n 1) ;;
      head-pod-delete)
        pod=$(k8s_pod "$run" head)
        ts=$(inject delete pod "$pod" --wait=false | head -n 1) ;;
    esac
    echo "D2: $config at $ts"

    rc=0
    wait "$TRAIN_PID" || rc=$?
    out=$(analyze resume "$run" --since "$ts" || true)
    echo "$out"
    # D2's pass rule (SPEC §11) does not include C4: after a head pod is recreated, Ray may place both
    # Train workers on the new head before the worker pod rejoins (SPREAD is best effort). C4 is
    # recorded as its own row instead.
    verify_run "$run" || true
    verified=0
    if grep -q "^verify $run:" ".data/drills/$run.verify" && ! grep '^FAIL' ".data/drills/$run.verify" | grep -qv '^FAIL C4'; then
      verified=1
    fi
    spread=1
    grep -q '^FAIL C4' ".data/drills/$run.verify" && spread=0
    t=$(kv time_to_resume_s <<< "$out") lost=$(kv steps_lost <<< "$out")
    restarts=$(kv restart_count <<< "$out") per_epoch=$(kv steps_per_epoch <<< "$out")
    csv_row D2_time_to_resume_s "$config" "$rep" "${t:-NA}" s "$run"
    csv_row D2_steps_lost "$config" "$rep" "${lost:-NA}" steps "$run"
    csv_row D2_restart_count "$config" "$rep" "${restarts:-NA}" restarts "$run"
    csv_row D2_workers_on_two_nodes "$config" "$rep" "$spread" bool "$run"
    if (( rc == 0 && verified && ${restarts:-0} >= 1 )) && [[ -n "$t" ]] && (( ${lost:-1000000} <= ${per_epoch:-0} )); then
      csv_row D2_outcome "$config" "$rep" pass outcome "$run"
    else
      echo "D2: $run FAILED (exit $rc, verify $verified, restarts=$restarts, steps_lost=$lost/$per_epoch)" >&2
      csv_row D2_outcome "$config" "$rep" fail outcome "$run"
      failed=1
    fi
  done
done
echo "D2 $SCHED: $([[ $failed == 0 ]] && echo PASS || echo FAIL) ($CSV)"
exit "$failed"
