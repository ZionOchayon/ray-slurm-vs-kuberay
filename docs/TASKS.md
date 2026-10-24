# v0.1 build plan: Ray on Slurm (re-planned 14:35)

**Target:** Sat 24 Oct 2026, from 14:35 to the hard stop at 17:00 Israel time. **Budget:** 130 min of tasks plus 15 min of slack.
**Spec:** `docs/SPEC.md`. The requirement IDs below refer to it. This file is enough to build v0.1 on its own; the spec holds the reasons and the v0.2 plan.

## Rules

- Run everything (git, make, docker compose) from an **Ubuntu shell in WSL2**, in `~/code/ray-slurm-vs-kuberay`. Never work under `/mnt/c`. Docker Desktop must use the WSL2 backend.
- Before the first commit, `git config user.email` must print exactly `183262811+ZionOchayon@users.noreply.github.com`. If it does not, stop.
- Do the tasks in order. Each ends with its done-check, and the next starts only after that passes.
- After each task, report one line: task, done-check result, minutes spent.
- If a task runs **15 min over** its estimate, stop and tell the owner before continuing.
- **At 16:45, whatever the state:** write README v0.1 and push to the **private** repo. It goes public only if a clean clone works and CI is green.
- Anything that behaves differently from what this file expects gets one line in `docs/NOTES.md` (time, expected, observed).

## Facts you need (verified 2026-10-24 against primary sources)

1. **`ray symmetric-run` (Ray 2.59.0).**
   - Usage: `ray symmetric-run --address HOST:PORT [--min-nodes N] [ray start options] -- <entrypoint>`.
   - It rejects `--head`, `--port`, `--node-ip-address` and `--block`.
   - A node is the head if the `--address` IP is one of its own interface IPs. The entrypoint runs only on the head.
   - It waits `RAY_SYMMETRIC_RUN_CLUSTER_WAIT_TIMEOUT` seconds (default 30).
   - It prints `On head node.` or `On worker node.`
   - It returns the entrypoint's non-zero exit code, **but exits 0 if `ray start` fails on the head**, so always verify artifacts.
   - It refuses to start if Ray is already running on the node.
2. **Ray Train shared storage.** Multi-node checkpointing needs a shared filesystem; a node-local `storage_path` raises an error. `/data` is one Docker volume shared by every container.
3. **Ray Train V2 is the default in 2.59.0.**
   - `ray.train.report(metrics, checkpoint=None, checkpoint_dir_name=None)` is a barrier: **every rank calls it the same number of times**, and only rank 0 passes a checkpoint.
   - `checkpoint_dir_name` must be unique per checkpoint.
   - Use `ScalingConfig(num_workers, use_gpu, placement_strategy)`, `CheckpointConfig(num_to_keep=None)` and `FailureConfig(max_failures)`.
4. **Slurm base image** `giovtorres/slurm-docker-cluster:26.05.5-3.0.2`:
   - Rocky Linux 9; its Dockerfile installs `python3.12` as `python3`.
   - Default partition `cpu`.
   - Compute nodes self-register as `c1`, `c2` (service `cpu-worker`, `deploy.replicas`).
   - Shared volume `slurm_jobdir` at `/data`.
   - The containers are privileged.
   - No cgroup enforcement (`proctrack/linuxproc`), so Ray must get `--num-cpus` explicitly.
   - Upstream compose: https://raw.githubusercontent.com/giovtorres/slurm-docker-cluster/3.0.2/docker-compose.yml (MIT).
5. **Wheels.** torch `2.14.1+cpu` and torchvision `0.29.1+cpu` from `https://download.pytorch.org/whl/cpu` (cp310–cp314, x86_64 and aarch64). `ray[train]==2.59.0` from PyPI, which needs Python ≥ 3.10.
6. **CI target.** The private-repo runner: 2 vCPU, 7 GB RAM (design value), 14 GB SSD. Two Ray nodes × `--cpus-per-task=2` fit it, because each node container sees the runner's 2 CPUs.

## Interface (from SPEC §9)

- **Targets:** `make up`, `make train-slurm`, `make verify`, `make down`.
- **Variables and defaults:**
  - `RUN` defaults to `slurm-<UTC yyyymmdd-HHMMSS>` and must match `^[a-z0-9]([a-z0-9-]{0,40}[a-z0-9])?$`
  - `EPOCHS=2`, `WORKERS=2`, `DATA=synthetic`, `SAMPLES=8192`
  - `TIMEOUT=1200`, `MIN_MEM_GIB=6`
- **Exit codes:** `0` ok, `1` failed, `2` invalid input, `124` timeout.

## Schedule

| Task                                               | Start | Budget       | Stop-and-ask at | Closes                                                  |
| -------------------------------------------------- | ----- | ------------ | --------------- | ------------------------------------------------------- |
| T0 Host check, WSL repo, hygiene                   | 14:35 | 15           | 15:05           | NFR-06 (email), NFR-07, NFR-08 (LICENSE), NFR-01 (file) |
| T1 Slurm node image                                | 14:50 | 20           | 15:25           | NFR-01, NFR-05 (amd64)                                  |
| T2 Compose cluster, `make up` / `make down`        | 15:10 | 25           | 15:50           | FR-01, FR-02, FR-09, FR-11                              |
| T3 `train/train.py`                                | 15:35 | 20           | 16:10           | FR-04, FR-05                                            |
| T4 sbatch, `make train-slurm`, `make verify`       | 15:55 | 30           | 16:40           | FR-03, FR-06, FR-07, FR-08, NFR-10, NFR-04              |
| T5 CI workflow and private push                    | 16:25 | 10           | 16:50           | FR-10, NFR-02, CI hygiene                               |
| T6 README v0.1, clean-clone gate, publish if green | 16:35 | 10           | (16:45 rule)    | SC-01, SC-03, NFR-03, NFR-06 (denylist), NFR-09         |
| Slack                                              | 16:45 | 15           | n/a             | none                                                    |
| **Total**                                          |       | **130 + 15** |                 |                                                         |

While T1's image builds, draft T3.

---

## T0: Host check, WSL repo, hygiene (15 min)

**Goal:** a WSL2 Ubuntu shell where docker, compose, make and git work; a repo in the WSL filesystem that can only commit with the noreply email; the skeleton files.

**Steps**

1. On Windows, `wsl -l -v` must list an Ubuntu distro at VERSION 2, and `docker version` must show a **Server** section. Record both outputs, plus `docker compose version`, in SPEC §16 R2.
   - If WSL is missing, run `wsl --install -d Ubuntu-24.04` in an **elevated** PowerShell, reboot if asked, then enable Docker Desktop → Settings → Resources → WSL integration → Ubuntu-24.04. This is the owner's action, and its time counts against slack.
2. In Ubuntu: `sudo apt-get update && sudo apt-get install -y make git`.
3. Create the repo with `mkdir -p ~/code/ray-slurm-vs-kuberay && cd ~/code/ray-slurm-vs-kuberay && git init -b main`. Copy `docs/` from `/mnt/c/Projects/RayOnSlurm/docs`; that Windows folder is not used after this.
4. Set the identity with `git config user.name "Zion Ochayon"` and `git config user.email "183262811+ZionOchayon@users.noreply.github.com"`. Check that `env | grep -E 'GIT_(AUTHOR|COMMITTER)_EMAIL'` is empty, because those variables would override the config.
5. Create the files:
   - `.gitattributes`:
     ```
     * text=auto eol=lf
     *.sh text eol=lf
     *.sbatch text eol=lf
     Makefile text eol=lf
     Dockerfile text eol=lf
     ```
   - `.gitignore`: `.runs/` and `.data/`.
   - `LICENSE`: verbatim from https://www.apache.org/licenses/LICENSE-2.0.txt.
   - `NOTICE`: the project name, then "Includes a docker-compose file derived from giovtorres/slurm-docker-cluster 3.0.2 (MIT), see slurm/LICENSE.slurm-docker-cluster".
   - `docs/NOTES.md`: a heading only.
   - `README.md`: a one-line stub.
   - `versions.env`, exactly:
     ```
     SLURM_VERSION=26.05.5
     SLURM_BASE_IMAGE=giovtorres/slurm-docker-cluster:26.05.5-3.0.2@sha256:947fca3c27d78abcdf97f21639e3483a2d6c0569ec812cb514e9cdf2526e0d90
     MARIADB_IMAGE=mariadb:12@sha256:99c125f103f5d081ebbc9ffe064e63daf7f688ac33a5f7f29af2d7260a96debf
     RAY_VERSION=2.59.0
     TORCH_VERSION=2.14.1
     TORCHVISION_VERSION=0.29.1
     ```
6. Create the local denylist **outside the repo** at `~/.config/rayslurm/denylist.txt`: one former employer, client or project name per line. It is the owner's to fill and is never committed.
7. Make the first commit only after the done-check passes.

**Done-check** (in WSL, from the repo root):

```
docker version --format '{{.Server.Version}}' \
&& docker info --format '{{.MemTotal}}' \
&& make --version | head -1 \
&& test "$(git config user.email)" = 183262811+ZionOchayon@users.noreply.github.com \
&& test "$(grep -c '@sha256:' versions.env)" -ge 2 \
&& git add -A && ! git ls-files --eol | grep -q 'i/crlf' \
&& grep -q 'Apache License' LICENSE
```

`MemTotal` must be ≥ 6442450944 (6 GiB).

---

## T1: Slurm node image (20 min)

**Goal:** one image, used by slurmdbd, slurmctld and the compute nodes, that adds a Ray and PyTorch CPU venv to the upstream Slurm image.

**Files:** `slurm/Dockerfile`.

**Check first** (before writing the Dockerfile):

```
docker run --rm --entrypoint sh "$SLURM_BASE_IMAGE" -c 'python3 --version; python3 -m venv /tmp/v && /tmp/v/bin/pip --version'
```

`SLURM_BASE_IMAGE` comes from `versions.env`. If Python is missing or older than 3.10, or `venv`/`pip` fails, install `uv` (copy the static binary from the official `ghcr.io/astral-sh/uv` image at a pinned tag, added to `versions.env`). Then create the venv with `uv venv --python 3.12 /opt/venv` and install with `uv pip`. Record which path was taken in NOTES.

**Dockerfile behavior:**

- `ARG SLURM_BASE_IMAGE`, then `FROM ${SLURM_BASE_IMAGE}`.
- Then `ARG RAY_VERSION`, `ARG TORCH_VERSION` and `ARG TORCHVISION_VERSION`, with **no defaults**.
- Create the venv at `/opt/venv`.
- Install `torch==${TORCH_VERSION}` and `torchvision==${TORCHVISION_VERSION}` with `--index-url https://download.pytorch.org/whl/cpu`, then `"ray[train]==${RAY_VERSION}"` from PyPI. Use `--no-cache-dir`.
- Do not change `ENTRYPOINT`, `CMD`, `USER` or the global `PATH`.

**Done-check:**

```
set -a; . ./versions.env; set +a
docker build -f slurm/Dockerfile --build-arg SLURM_BASE_IMAGE --build-arg RAY_VERSION \
  --build-arg TORCH_VERSION --build-arg TORCHVISION_VERSION -t "rayslurm-node:${RAY_VERSION}-${SLURM_VERSION}" . \
&& docker run --rm --entrypoint /opt/venv/bin/python "rayslurm-node:${RAY_VERSION}-${SLURM_VERSION}" \
     -c "import ray, torch; print(ray.__version__, torch.__version__)" | grep -qx '2.59.0 2.14.1+cpu' \
&& docker run --rm --entrypoint sbatch "rayslurm-node:${RAY_VERSION}-${SLURM_VERSION}" --version
```

The last command must print `slurm 26.05.5`. Commit.

---

## T2: Compose cluster, `make up`, `make down` (25 min)

**Goal:** `make up` returns only when 2 nodes are idle; `make down` removes everything; a low-memory engine fails fast.

**Files:** `slurm/docker-compose.yml`, `slurm/LICENSE.slurm-docker-cluster`, `scripts/up.sh`, `Makefile`.

**Steps**

1. Download the upstream `docker-compose.yml` and `LICENSE` at tag `3.0.2`. Add a first-line comment: `# Derived from giovtorres/slurm-docker-cluster 3.0.2 (MIT). See NOTICE.`
2. Edit the compose file:
   - **Delete** the services `slurmrestd`, `gpu-worker`, `ondemand`, `elasticsearch` and `kibana`, and the volume `elasticsearch_data`.
   - **Keep** `mysql`, `slurmdbd`, `slurmctld` and `cpu-worker`, each with all of its volume mounts, `privileged`, `init`, `command`, `healthcheck`, `depends_on`, `deploy.replicas: 2` and the `COMPOSE_PROJECT_NAME` env entry.
   - `mysql`: set `image: ${MARIADB_IMAGE}`.
   - The other three: set `image: rayslurm-node:${RAY_VERSION}-${SLURM_VERSION}` and remove their upstream `build:` blocks.
   - Give `slurmctld` the only `build:`, with `context: ..`, `dockerfile: slurm/Dockerfile` and the four args from the environment.
   - `slurmctld`: remove `ports:` and the `SSH_AUTHORIZED_KEYS` bind mount.
   - `slurmctld` and `cpu-worker`: add `..:/opt/rayslurm:ro`.
   - `cpu-worker`: add `shm_size: "1gb"`.
3. Makefile header (interface):
   ```
   include versions.env
   export
   COMPOSE := docker compose -p slurm --env-file versions.env -f slurm/docker-compose.yml
   MIN_MEM_GIB ?= 6
   .PHONY: up down train-slurm verify
   up:   ; COMPOSE="$(COMPOSE)" MIN_MEM_GIB=$(MIN_MEM_GIB) scripts/up.sh
   down: ; $(COMPOSE) down -v --remove-orphans
   ```
4. `scripts/up.sh` (bash, `set -euo pipefail`):
   1. Preflight. If the engine is unreachable, print `preflight: docker engine unreachable` and exit 1. If `MemTotal` < `MIN_MEM_GIB` GiB, print `preflight: engine memory <have> GiB < required <need> GiB` and exit 1. Otherwise print `preflight ok`.
   2. `$COMPOSE build`, then `$COMPOSE up -d --wait`.
   3. `docker exec slurmctld mkdir -p /data/logs /data/ray_results`.
   4. Poll up to 180 s, every 5 s, until `docker exec slurmctld sinfo -h -p cpu -t idle -o %D` prints `2`. If it never does, print `sinfo` and exit 124.
   5. Print `sinfo` and exit 0.

**Done-check:**

```
! make up MIN_MEM_GIB=1024 > /tmp/pf.log 2>&1 && grep -q 'preflight: engine memory' /tmp/pf.log \
&& make up \
&& docker exec slurmctld sinfo -h -p cpu -t idle -o %D | grep -qx 2 \
&& docker exec slurm-cpu-worker-1 sh -c 'echo ok > /data/.probe' \
&& docker exec slurm-cpu-worker-2 grep -qx ok /data/.probe \
&& docker exec slurm-cpu-worker-1 test -f /opt/rayslurm/versions.env \
&& make down && make down \
&& test -z "$(docker ps -aq --filter label=com.docker.compose.project=slurm)"
```

Then `make up` again, leave the cluster running, and commit.

**If stuck after 15 min:** bring up the upstream compose unmodified to tell an upstream problem from a trimming mistake. Restore whatever the entrypoint needs, and log it in NOTES.

---

## T3: `train/train.py` (20 min)

**Goal:** a small CNN trained on synthetic data with a Ray Train TorchTrainer, with a checkpoint every epoch. No resume and no event log (both moved to v0.2).

**Files:** `train/train.py`.

**Flags:**

| Flag                  | Default             | Notes                                      |
| --------------------- | ------------------- | ------------------------------------------ |
| `--run-name`          | required            | Must match the RUN regex; exit 2 otherwise |
| `--storage-path`      | `/data/ray_results` |                                            |
| `--epochs`            | 2                   | int ≥ 1                                    |
| `--workers`           | 2                   | int ≥ 1                                    |
| `--data`              | `synthetic`         | `choices=["synthetic"]`                    |
| `--synthetic-samples` | 8192                |                                            |
| `--batch-size`        | 128                 |                                            |
| `--seed`              | 0                   |                                            |
| `--max-failures`      | 3                   |                                            |

**Behavior**

1. Set `os.environ.setdefault("RAY_TRAIN_V2_ENABLED", "1")` before importing `ray.train`.
2. Data: a seeded `torch.Generator`. Inputs are `randn(N, 1, 28, 28)` float32 and labels `randint(0, 10, (N,))`, wrapped in a `TensorDataset`, then a `DataLoader`, then `ray.train.torch.prepare_data_loader`. No files and no network.
3. Model: Conv(1→16, k3), ReLU, MaxPool2, Conv(16→32, k3), ReLU, MaxPool2, Flatten, Linear(800→10). Wrap it with `prepare_model`. Use SGD and cross-entropy.
4. On the first epoch, gather `ray.util.get_node_ip_address()` from all ranks with `torch.distributed.all_gather_object`. This gives `worker_node_ips`.
5. At the end of each epoch:
   - Rank 0 saves `{"model", "optimizer", "epoch", "global_step"}` to `<tmpdir>/model.pt`.
   - **Every** rank calls `ray.train.report({"epoch", "loss", "global_step", "worker_node_ips"}, checkpoint=<rank 0 only>, checkpoint_dir_name=f"checkpoint_epoch_{epoch:03d}")`.
6. Driver: `TorchTrainer(…, scaling_config=ScalingConfig(num_workers=W, use_gpu=False, placement_strategy="SPREAD"), run_config=RunConfig(name=run, storage_path=…, checkpoint_config=CheckpointConfig(num_to_keep=None), failure_config=FailureConfig(max_failures=M)))`.
7. After `fit()`, write `<storage>/<run>/run.json` with:
   - `run`, `scheduler` (`slurm` if `SLURM_JOB_ID` is set, else `local`), `job_id`
   - `epochs`, `workers`, `data`, `samples`, `batch_size`, `seed`
   - `worker_node_ips`, `final_loss`
   - `ray_version`, `torch_version`, `torch_num_threads`
   - `status: "finished"`
8. Do not catch exceptions from `fit()`. A failure must exit non-zero.

**Done-check** (a single-node smoke test with local Ray in one compute container):

```
docker exec slurm-cpu-worker-1 /opt/venv/bin/python /opt/rayslurm/train/train.py \
  --run-name smoke-t3 --epochs 2 --workers 2 --synthetic-samples 512 \
&& docker exec slurm-cpu-worker-1 test -f /data/ray_results/smoke-t3/checkpoint_epoch_000/model.pt \
&& docker exec slurm-cpu-worker-1 test -f /data/ray_results/smoke-t3/checkpoint_epoch_001/model.pt \
&& docker exec slurm-cpu-worker-1 grep -q '"status": "finished"' /data/ray_results/smoke-t3/run.json \
&& ! docker exec slurm-cpu-worker-1 pgrep -f gcs_server
```

A leftover local Ray would block T4. If the last line fails, run `docker exec slurm-cpu-worker-1 /opt/venv/bin/ray stop`. Commit.

---

## T4: sbatch, `make train-slurm`, `make verify` (30 min)

**Goal:** a 2-node Slurm job runs `train.py` through `ray symmetric-run`, and `verify` proves it from artifacts.

**Files:** `slurm/sbatch/ray-symmetric.sbatch`, `scripts/train-slurm.sh`, `scripts/verify.py`, `Makefile`, `docs/NOTES.md`.

**`ray-symmetric.sbatch`.** The directives are the interface:

```
#!/bin/bash
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=2
#SBATCH --time=00:30:00
#SBATCH --output=/data/logs/%x-%j.out
```

The body:

1. `set -euo pipefail`. Require `RUN`, `EPOCHS`, `WORKERS`, `DATA` and `SAMPLES` with `${VAR:?}`.
2. `export PATH=/opt/venv/bin:$PATH RAY_TRAIN_V2_ENABLED=1 RAY_SYMMETRIC_RUN_CLUSTER_WAIT_TIMEOUT=120`.
3. Head address, following Ray's Slurm docs pattern:
   - `head_node` = first entry of `scontrol show hostnames "$SLURM_JOB_NODELIST"`.
   - `head_ip=$(srun --nodes=1 --ntasks=1 -w "$head_node" hostname --ip-address)`. Echo both.
   - **Fallback, only if that fails** (empty, a loopback address, or `symmetric-run` never says `On head node.`): use the first word of `hostname -I` from the same `srun`, and log it in NOTES under "gotchas".
4. `srun --nodes=2 --ntasks=2 --ntasks-per-node=1 ray symmetric-run --address "$head_ip:6379" --min-nodes 2 --num-cpus="$SLURM_CPUS_PER_TASK" --num-gpus=0 -- python -u /opt/rayslurm/train/train.py --run-name "$RUN" --epochs "$EPOCHS" --workers "$WORKERS" --data "$DATA" --synthetic-samples "$SAMPLES"`

**`scripts/train-slurm.sh`** (bash, `set -euo pipefail`):

1. Validate `RUN` against the regex and check that `EPOCHS`, `WORKERS`, `SAMPLES` and `TIMEOUT` are positive integers; exit 2 otherwise. Do **not** validate `DATA`.
2. If `docker exec slurmctld sinfo` fails, print `cluster not up: run make up` and exit 1.
3. `rc=0; timeout "$TIMEOUT" docker exec slurmctld sbatch --parsable --wait --job-name="$RUN" --export=ALL,RUN=…,EPOCHS=…,WORKERS=…,DATA=…,SAMPLES=… /opt/rayslurm/slurm/sbatch/ray-symmetric.sbatch || rc=$?`. If `rc` is 124, run `docker exec slurmctld scancel --name="$RUN"`.
4. Get the job ID from `docker exec slurmctld sacct -n -X -P --name="$RUN" -o JobID | tail -1`. Write it to `.runs/$RUN.jobid`, and write `$RUN` to `.runs/latest`.
5. Print RUN, the job ID, `State,ExitCode,Elapsed`, the log path and `tail -n 40` of the log.
6. Exit 124 on timeout, 0 if `COMPLETED`, 1 otherwise.

**`scripts/verify.py`** (runs inside slurmctld; stdlib only):

- Arguments: `--run`, `--job-id`, `--storage /data/ray_results`, `--log-dir /data/logs`.
- Checks, each printing `PASS Cn` or `FAIL Cn` with a reason:
  - **C1:** `sacct -j <id> -X -n -P -o State,ExitCode` gives `COMPLETED|0:0`. Retry for up to 30 s.
  - **C2:** `run.json.status == "finished"`.
  - **C3:** the number of `checkpoint_epoch_*` directories equals `epochs`, and each has `model.pt`.
  - **C4:** if `workers == 2`, there are 2 distinct `worker_node_ips`.
  - **C5:** the log has exactly one `On head node.` and one `On worker node.`
- Exit 0 if all pass, 1 if any fails, 2 on bad arguments.

**Makefile additions:**

```
RUN ?= slurm-$(shell date -u +%Y%m%d-%H%M%S)
EPOCHS ?= 2
WORKERS ?= 2
DATA ?= synthetic
SAMPLES ?= 8192
TIMEOUT ?= 1200
train-slurm: ; RUN=$(RUN) EPOCHS=$(EPOCHS) WORKERS=$(WORKERS) DATA=$(DATA) SAMPLES=$(SAMPLES) TIMEOUT=$(TIMEOUT) scripts/train-slurm.sh
```

`verify` takes `RUN` from the command line, or from `.runs/latest` if it is not given (exit 2 if neither exists). It then runs:
`docker exec slurmctld /opt/venv/bin/python /opt/rayslurm/scripts/verify.py --run <RUN> --job-id $(cat .runs/<RUN>.jobid)`

**Done-check:**

```
make train-slurm EPOCHS=2 RUN=t4-ok \
&& make verify RUN=t4-ok \
&& docker exec slurmctld rm -rf /data/ray_results/t4-ok/checkpoint_epoch_001 \
&& ! make verify RUN=t4-ok \
&& ! make train-slurm RUN=t4-neg DATA=bogus \
&& docker exec slurmctld sacct -n -X -P --name=t4-neg -o State | grep -q FAILED
```

During one run, take `docker stats --no-stream` and note the total memory in NOTES. If the total leaves less than 1 GiB of headroom under 7 GB, lower the default `SAMPLES` or `--cpus-per-task` before CI.

**Also note in NOTES:**

- which head-address path worked
- whether the job ended promptly after training
- the worker step's exit code (`sacct -j <id>`)

Commit.

---

## T5: CI workflow and private push (10 min)

**Goal:** every push to `main` proves the v0.1 MUSTs on a clean runner sized like the private runner.

**Files:** `.github/workflows/ci.yml`.

**Workflow settings:** `name: ci`, triggered by `push` to `main`, `pull_request` and `workflow_dispatch`; `permissions: contents: read`; a concurrency group per ref with cancel-in-progress; one job `slurm` on `ubuntu-24.04` with `timeout-minutes: 30`.

**Steps, in order:**

1. `actions/checkout@v7.0.1` with `fetch-depth: 0`.
2. **Hygiene: pins.** `! grep -nE ':latest\b|@latest\b' versions.env slurm/Dockerfile slurm/docker-compose.yml .github/workflows/*.yml && test "$(grep -c '@sha256:' versions.env)" -ge 2`
3. **Hygiene: line endings.** `! git ls-files --eol | grep -q 'i/crlf'`
4. **Hygiene: license.** `grep -q 'Apache License' LICENSE && grep -q slurm-docker-cluster NOTICE && grep -q MIT slurm/LICENSE.slurm-docker-cluster`
5. **Hygiene: banned phrases.** `! grep -niE 'production[- ](grade|ready)|enterprise[- ]grade|scales to' README.md`
6. **Hygiene: commit emails.** `test -z "$(git log --format='%ae%n%ce' | sort -u | grep -v '@users.noreply.github.com$')"`
7. **Preflight negative.** `make up MIN_MEM_GIB=1024` must fail and print `preflight: engine memory` (make returns 2 for any recipe failure)
8. **Up.** `make up`
9. **Shared /data probe.** The two `/data/.probe` commands from T2.
10. **Train.** `make train-slurm EPOCHS=2 RUN=ci-${{ github.run_id }}`
11. **Verify.** `make verify RUN=ci-${{ github.run_id }} && ! docker exec slurmctld test -e /data/datasets`
12. **Negative verify.** Delete `checkpoint_epoch_001`, then `! make verify …`
13. **Negative train.** `! make train-slurm RUN=ci-neg-${{ github.run_id }} DATA=bogus`
14. **Collect logs** (`if: failure()`): write the compose logs and `tar` of `/data/logs` and `/data/ray_results` into `artifacts/`, then `actions/upload-artifact@v7.0.2`.
15. **Down** (`if: always()`). `make down`

**Private push.** `gh repo create ray-slurm-vs-kuberay --private --source . --push`. If `gh` isn't authenticated in WSL, run `gh auth login` first; that is the owner's step.

**Done-check:**

```
gh run watch --exit-status "$(gh run list --workflow ci.yml --limit 1 --json databaseId -q '.[0].databaseId')"
```

If the private runner fails `make up`'s preflight because its engine memory is just under 6 GiB, set CI's `MIN_MEM_GIB` from the T4 measurement, never below measured peak + 1 GiB, and note it.

---

## T6: README v0.1, clean-clone gate, publish if green (10 min; must start by 16:45)

**README v0.1**, in this order:

1. Title, the positioning line, the CI and license badges.
2. "What works today": Slurm side, a 2-node Ray Train job with a checkpoint per epoch, verified in CI; KubeRay, planned for **v0.2 (30–31 Oct 2026)**.
3. The honesty line: "CPU-only lab on one machine: it compares launchers and recovery, not hardware. Every number will come from `bench/`."
4. Quickstart: prerequisites, then `make up`, `make train-slurm`, `make verify` and `make down`, with what PASS looks like.
5. **Tested hosts:** Linux (CI) and Windows 11 through WSL2. **macOS: untested.**
6. The SPEC §8.2 Mermaid diagram.
7. Limits and non-goals.
8. Roadmap with dates.
9. Credits and license.

No timing numbers. Commit and push to the private repo (the 16:45 rule).

**Gate** (in WSL):

```
tmp=$(mktemp -d) && git clone "$(git remote get-url origin)" "$tmp/r" && cd "$tmp/r" \
&& time (make up && make train-slurm EPOCHS=1) && make verify && make down && cd - \
&& { git grep -niI -f ~/.config/rayslurm/denylist.txt; test $? -eq 1; } \
&& test "$(gh run list --workflow ci.yml --branch main --limit 1 --json conclusion -q '.[0].conclusion')" = success
```

Record the `time` output in NOTES as the SC-01 observation.

**Publish, only if the gate passed:**

1. `gh repo edit --visibility public --accept-visibility-change-consequences`
2. Rerun CI, and wait for it to pass.
3. `git tag -a v0.1.0 -m "v0.1: Ray on Slurm" && git push origin v0.1.0`

If the gate fails, the repo stays private.

---

## Cut order if behind

Cut from the top first:

1. The Mermaid diagram in the README (replace it with 5 lines of text).
2. CI step 13 (negative train).
3. CI step 12 (negative verify).
4. FR-11's negative preflight in CI (step 7).

**Never cut:** the T0 email check, `make verify` C1–C5, the CI run, the private push at 16:45, or the clean-clone gate before going public.

## Moved to v0.2

- FR-12 resume from checkpoint and FR-13 `events.jsonl`. Dropped from v0.1 entirely; both are MUST in v0.2.
- FR-14 `train.py` sha256 and verify check C6 (from the cut order).
- FR-20 FashionMNIST data path. v0.1 is synthetic only.
- FR-30 arm64 and kind CI jobs; FR-31 hash-locked dependencies; FR-32 weekly scheduled CI.
- Two concurrent jobs (D3) and all drills, bench and KubeRay work.
- Re-checking the UNVERIFIED items at the start of v0.2 (Fri 30 Oct): KubeRay with Kubernetes 1.37, RayJob `backoffLimit`, Helm 4, Slinky 1.2.0.
