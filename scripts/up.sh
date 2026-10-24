#!/usr/bin/env bash
# `make up`: preflight, build, start the Slurm cluster, wait until both compute nodes are idle.
# Exit: 0 ready, 1 preflight or compose failure, 124 nodes not idle in time.
set -euo pipefail
: "${COMPOSE:?}" "${MIN_MEM_GIB:?}"

mem=$(docker info --format '{{.MemTotal}}' 2>/dev/null || true)
if [[ ! "$mem" =~ ^[0-9]+$ || "$mem" -eq 0 ]]; then
  echo "preflight: docker engine unreachable" >&2
  exit 1
fi
if (( mem < MIN_MEM_GIB * 1024 ** 3 )); then
  echo "preflight: engine memory $(( mem / 1024 ** 3 )) GiB < required ${MIN_MEM_GIB} GiB" >&2
  exit 1
fi
echo "preflight ok: engine memory $(( mem / 1024 ** 3 )) GiB, arch $(docker info --format '{{.Architecture}}')"

$COMPOSE build
$COMPOSE up -d --wait
docker exec slurmctld mkdir -p /data/logs /data/ray_results

for _ in $(seq 36); do
  if [[ "$(docker exec slurmctld sinfo -h -p cpu -t idle -o %D 2>/dev/null)" == "2" ]]; then
    docker exec slurmctld sinfo
    exit 0
  fi
  sleep 5
done
docker exec slurmctld sinfo >&2 || true
echo "up: 2 idle nodes in partition cpu not reached within 180 s" >&2
exit 124
