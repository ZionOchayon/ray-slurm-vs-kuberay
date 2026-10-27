#!/usr/bin/env bash
# Run bench/summarize.py inside a project image (no Python on the host). Arguments pass through,
# e.g. `bash bench/summarize.sh --check README.md`.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source versions.env; set +a
for image in "rayslurm-node:$RAY_VERSION-$SLURM_VERSION" "rayk8s:$RAY_VERSION"; do
  if docker image inspect "$image" >/dev/null 2>&1; then
    exec docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:/work" -w /work --entrypoint python3 "$image" \
      bench/summarize.py "$@"
  fi
done
echo "summarize: no project image found; run make up or make train-k8s first" >&2
exit 1
