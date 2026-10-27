#!/usr/bin/env bash
# Run bench/summarize.py inside a project image (no Python on the host). Arguments pass through,
# e.g. `bash bench/summarize.sh --check README.md`.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source versions.env; set +a
for image in "rayslurm-node:$RAY_VERSION-$SLURM_VERSION" "rayk8s:$RAY_VERSION"; do
  if docker image inspect "$image" >/dev/null 2>&1; then
    # As root (the Ray image's Python is not readable by other UIDs), then hand the files back.
    exec docker run --rm -v "$PWD:/work" -w /work -e OWNER="$(id -u):$(id -g)" --entrypoint bash "$image" -c \
      'python3 bench/summarize.py "$@"; rc=$?; chown -R "$OWNER" docs/results README.md; exit $rc' _ "$@"
  fi
done
echo "summarize: no project image found; run make up or make train-k8s first" >&2
exit 1
