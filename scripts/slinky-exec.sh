#!/usr/bin/env bash
# Run a command in Slinky's login pod (stdin passed through), the counterpart of `docker exec slurmctld`.
set -euo pipefail
pod=$(kubectl --context kind-rayk8s -n slurm get pods -l app.kubernetes.io/name=login \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[[ -n "$pod" ]] || { echo "slinky: no running login pod (run make up-slinky)" >&2; exit 1; }
exec kubectl --context kind-rayk8s -n slurm exec -i "$pod" -- "$@"
