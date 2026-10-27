#!/usr/bin/env bash
# Drill D3 (SPEC §11, FR-23, FR-27): two training jobs submitted back to back onto the same nodes.
#   Slurm: (a) default ray-symmetric, (b) EXCLUSIVE=1, (c) LAUNCHER=manual (per-job ports).
#   K8s:   (k) two RayJobs.
# Records M4 per rep: each job's terminal state and last error line, the outcome (concurrent, serialized,
# second-failed or other) and the makespan from the first submit to the last terminal state.
# Pass: the drill completes, and in (b) and (k) both runs pass `make verify`. A failure in (a) is the
# expected finding; a failure in (c) is recorded as a finding, not a drill defect (SPEC §11 D3).
# Exit: 0 pass, 1 fail, 2 invalid input.
set -euo pipefail
source drills/lib.sh
: "${REPS:?}"

if [[ $SCHED == slurm ]]; then configs=(a b c); else configs=(k); fi
# Shorter than D1/D2: the question is whether both jobs run, not how they recover.
DRILL_EPOCHS=${DRILL_EPOCHS:-2} DRILL_SAMPLES=${DRILL_SAMPLES:-16384}
export DRILL_EPOCHS DRILL_SAMPLES
csv_open drill-two-jobs
k8s_setup
failed=0

# Last line of a job's log that looks like an error, for the CSV.
job_message() {
  grep -iE 'error|exception|already|failed' ".data/drills/$1.log" | tail -n 1 | cut -c1-160 || true
}

for config in "${configs[@]}"; do
  case $config in
    a) env_args=() ;;
    b) env_args=(EXCLUSIVE=1) ;;
    c) env_args=(LAUNCHER=manual) ;;
    k) env_args=() ;;
  esac
  for rep in $(seq "$REPS"); do
    base="d3$config-$SCHED-$(date -u +%H%M%S)-$rep"
    echo "== D3 $SCHED ($config) rep $rep: $base-1 and $base-2"
    t0=$(vm_now)
    start_train "$base-1" "${env_args[@]}"
    pid1=$TRAIN_PID
    start_train "$base-2" "${env_args[@]}"
    pid2=$TRAIN_PID

    # Terminal timestamps from the VM clock, taken when each job's script returns.
    declare -A rc=() end=()
    while (( ${#end[@]} < 2 )); do
      for i in 1 2; do
        pid_var=pid$i
        if [[ -z "${end[$i]:-}" ]] && ! kill -0 "${!pid_var}" 2>/dev/null; then
          r=0
          wait "${!pid_var}" || r=$?
          rc[$i]=$r end[$i]=$(vm_now)
        fi
      done
      sleep 1
    done
    makespan=$(awk -v a="$t0" -v b="${end[1]}" -v c="${end[2]}" 'BEGIN { printf "%.3f", (b > c ? b : c) - a }')

    ok=()
    for i in 1 2; do
      run="$base-$i"
      v=0
      [[ ${rc[$i]} == 0 ]] && verify_run "$run" && v=1
      ok[$i]=$v
      csv_row D3_job_exit "$config" "$rep.$i" "${rc[$i]}" code "$run"
      csv_row D3_job_verified "$config" "$rep.$i" "$v" bool "$run"
      csv_row D3_job_message "$config" "$rep.$i" "$(job_message "$run")" text "$run"
    done
    # Overlap from the events: did job 2's driver start before job 1's run ended (or vice versa)?
    s1=$(analyze span "$base-1" || true) s2=$(analyze span "$base-2" || true)
    st1=$(kv start_ts <<< "$s1") en1=$(kv end_ts <<< "$s1") st2=$(kv start_ts <<< "$s2") en2=$(kv end_ts <<< "$s2")
    if (( ok[1] && ok[2] )); then
      if awk -v a="$st1" -v b="$en1" -v c="$st2" -v d="$en2" 'BEGIN { exit !(c < b && a < d) }'; then
        outcome=both-concurrent
      else
        outcome=serialized
      fi
    elif (( ok[1] != ok[2] )); then
      outcome=second-failed
    else
      outcome=both-failed
    fi
    echo "D3 ($config) rep $rep: $outcome, exits ${rc[1]}/${rc[2]}, makespan ${makespan}s"
    csv_row M4_outcome "$config" "$rep" "$outcome" outcome "$base"
    csv_row M4_makespan_s "$config" "$rep" "$makespan" s "$base"
    if [[ $config =~ ^(b|k)$ ]] && (( ! (ok[1] && ok[2]) )); then
      echo "D3: ($config) rep $rep expected both runs to verify" >&2
      failed=1
    fi
    unset rc end
  done
done
echo "D3 $SCHED: $([[ $failed == 0 ]] && echo PASS || echo FAIL) ($CSV)"
exit "$failed"
