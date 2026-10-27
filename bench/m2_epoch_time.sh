#!/usr/bin/env bash
# M2 (SPEC §10): seconds per epoch with 1 and 2 Ray Train workers on the same 2-node allocation
# (Slurm) or the same head + worker pod pair (K8s). REPS_M2 runs per worker count, EPOCHS=3,
# SAMPLES=60000, batch 128; epoch 0 is warm-up and is not reported. Checkpoint time is separate.
# Exit: 0 every run measured, 1 otherwise.
set -euo pipefail
source drills/lib.sh
: "${REPS_M2:?}"

csv_open m2
k8s_setup
failed=0
for workers in ${M2_WORKERS:-1 2}; do
  for rep in $(seq "$REPS_M2"); do
    run="m2-$SCHED-w$workers-$(date -u +%H%M%S)-$rep"
    DRILL_EPOCHS=3 DRILL_SAMPLES=60000 start_train "$run" WORKERS="$workers"
    rc=0
    wait "$TRAIN_PID" || rc=$?
    out=$(analyze m2 "$run" || true)
    if (( rc != 0 )) || ! grep -q '^epoch=' <<< "$out"; then
      echo "M2 $SCHED w$workers rep $rep ($run): failed (exit $rc)" >&2
      failed=1
      continue
    fi
    while read -r e t c; do
      e=${e#epoch=} t=${t#epoch_train_s=} c=${c#ckpt_s=}
      (( e >= 1 )) || continue
      csv_row M2_epoch_train_s "w$workers" "$rep.e$e" "$t" s "$run"
      csv_row M2_ckpt_s "w$workers" "$rep.e$e" "$c" s "$run"
    done < <(grep '^epoch=' <<< "$out")
    csv_row M2_torch_num_threads "w$workers" "$rep" "$(kv torch_num_threads <<< "$out")" threads "$run"
    echo "M2 $SCHED w$workers rep $rep ($run): $(grep '^epoch=' <<< "$out" | tr '\n' ' ')"
  done
done
exit "$failed"
