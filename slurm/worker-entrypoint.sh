#!/bin/bash
# Compute-node entrypoint: wait until every cpu-worker replica's compose DNS name resolves, then run the
# upstream entrypoint unchanged. Upstream finds its replica number by resolving
# ${COMPOSE_PROJECT_NAME}-cpu-worker-1, -2, ... in order and exits 1 (set -e) if a lower-numbered
# replica does not resolve yet, a start-up race seen in CI on 2026-10-27 (docs/NOTES.md).
set -euo pipefail
: "${COMPOSE_PROJECT_NAME:?}" "${CPU_WORKERS:?}"
for _ in $(seq 60); do
  missing=0
  for i in $(seq "$CPU_WORKERS"); do
    getent hosts "$COMPOSE_PROJECT_NAME-cpu-worker-$i" >/dev/null || missing=1
  done
  (( missing )) || break
  sleep 1
done
exec /usr/local/bin/docker-entrypoint.sh "$@"
