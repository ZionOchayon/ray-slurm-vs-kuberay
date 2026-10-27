#!/usr/bin/env bash
# `make bench` (SPEC FR-28): M1 and M2 on both schedulers, then the three drills on both, then
# bench/summarize.py (results.csv, table.md, README block). One scheduler at a time, so the two lab
# clusters never compete for the same CPUs; `docker stats` is sampled every 5 s for peak memory (NFR-04).
# BENCH_SCHEDS limits the schedulers (default "slurm k8s"). Exit: 0 every step passed, 1 otherwise.
set -euo pipefail
: "${REPS_M1:?}" "${REPS_M2:?}" "${REPS:?}"
mkdir -p .data/bench docs/results/raw
failed=0

step() {
  echo
  echo "=== bench: $*"
  if ! "$@"; then
    echo "bench: FAILED: $*" >&2
    failed=1
  fi
}

# Peak memory per container from `docker stats` samples (MiB), as raw CSV rows for one scheduler.
sample_stats() {
  while true; do
    docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' >> "$1" 2>/dev/null || true
    sleep 5
  done
}
write_peaks() {
  local sched=$1 samples=$2
  SCHED=$sched bash -c '
    source drills/lib.sh
    csv_open peak-mem
    awk '\''{ v = $2; u = v; sub(/[0-9.]+/, "", u); sub(/[A-Za-z]+$/, "", v)
             m = (u == "GiB") ? v * 1024 : (u == "KiB") ? v / 1024 : (u == "B") ? v / 1048576 : v
             if (m > peak[$1]) peak[$1] = m }
           END { for (c in peak) printf "%s %.0f\n", c, peak[c] }'\'' "$1" | sort |
      while read -r name mib; do csv_row NFR04_peak_mem_mib "$name" 1 "$mib" MiB bench; done
  ' _ "$samples"
}

for sched in ${BENCH_SCHEDS:-slurm k8s}; do
  stats=.data/bench/stats-$sched.txt
  : > "$stats"
  if [[ $sched == slurm ]]; then
    step make --no-print-directory up
  fi
  sample_stats "$stats" &
  sampler=$!
  step env SCHED="$sched" bash bench/m1_submit_to_first_step.sh
  step env SCHED="$sched" bash bench/m2_epoch_time.sh
  step env SCHED="$sched" bash drills/kill-worker.sh
  step env SCHED="$sched" bash drills/preempt.sh
  step env SCHED="$sched" bash drills/two-jobs.sh
  kill "$sampler" 2>/dev/null || true
  wait "$sampler" 2>/dev/null || true
  write_peaks "$sched" "$stats"
  # Free the machine for the next scheduler.
  if [[ $sched == slurm ]]; then
    docker compose -p slurm --env-file versions.env -f slurm/docker-compose.yml down -v --remove-orphans
    # BENCH_PRUNE=1 (CI): small runners do not have the disk for both stacks' images at once.
    if [[ "${BENCH_PRUNE:-0}" == 1 ]]; then
      docker image rm "rayslurm-node:$RAY_VERSION-$SLURM_VERSION" "$SLURM_BASE_IMAGE" "$MARIADB_IMAGE" || true
      docker builder prune -af >/dev/null || true
    fi
  else
    kind delete cluster --name rayk8s
  fi
done

step bash bench/summarize.sh
exit "$failed"
