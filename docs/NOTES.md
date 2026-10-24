# Build notes (observations, not results)

What actually happened while building, including surprises. Times are Israel time (+03:00). No number in this file is a benchmark.

## 2026-10-24 (v0.1)

- 14:29: Docker Desktop's UI was running, but the engine answered HTTP 500 and WSL was not installed, so the Linux engine VM had never started.
- 14:37: installed WSL 3.0.3 and the VirtualMachinePlatform feature with `wsl --install -d Ubuntu-24.04 --no-launch` (elevated). Windows needs a reboot before WSL works.
- Gotcha (from upstream `docker-entrypoint.sh` @3.0.2): compute containers rename themselves to `c1`/`c2` after start, and find their replica number by resolving `${COMPOSE_PROJECT_NAME}-cpu-worker-N`. So the compose project name must stay `slurm`, and `hostname --ip-address` for `c1` may not resolve. The sbatch falls back to `hostname -I` and prints `GOTCHA:` in the job log when it does.
- Gotcha: GNU make reports any failing recipe as exit 2, so `make up` cannot return the script's exit 1 or 124. The checks test for "non-zero" plus the message, not the exact code.
- Gotcha: GitHub Actions runs steps with `bash -e`, which ignores the status of `! cmd`. Negative CI checks use `if cmd; then exit 1; fi`.
