# ray-slurm-vs-kuberay

[![ci](https://github.com/ZionOchayon/ray-slurm-vs-kuberay/actions/workflows/ci.yml/badge.svg)](https://github.com/ZionOchayon/ray-slurm-vs-kuberay/actions/workflows/ci.yml)
[![license](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

**One PyTorch training job, three schedulers, side by side: Ray on Slurm, Ray on Kubernetes (KubeRay), and Slurm running inside Kubernetes (Slinky).** One-command local clusters, failure drills, measured results and a Grafana dashboard, all on a laptop or a free CI runner.

The same `train/train.py` (Ray Train, 2 CPU workers, a checkpoint every epoch) runs unchanged on all three. Every run is checked from its artifacts, and every number below is produced by a script.

## Key findings

- **Two `ray symmetric-run` jobs on the same Slurm nodes break each other**, and Slurm still reports `COMPLETED` for jobs that never trained. `--exclusive` or per-job Ray ports fix it.
- **Never trust the job state alone.** `make verify` checks the checkpoints, the job log and the `train.py` hash, and that is what caught the failure above.
- **Worker crashes recover on all three** through Ray Train's checkpoints. **Preemption** works on both Slurm (signal → requeue, same job ID) and KubeRay (pod deletion → resubmit), but a requeued Slurm job waits minutes before it restarts.

The full opinion, with every claim linked to a result row: [docs/when-to-use-which.md](docs/when-to-use-which.md).

## Results

<!-- results:start -->
| Metric | Slurm (ray symmetric-run) | KubeRay (RayJob on kind) | Slurm on K8s (Slinky) |
| --- | --- | --- | --- |
| M1 submit → first step, s: median [min–max] | [31.16 [30.892–31.9], n=5](/docs/results/results.csv#L84) | [41.305 [41.199–44.509], n=5](/docs/results/results.csv#L78) | [23.105 [22.413–34.879], n=5](/docs/results/results.csv#L81) |
| M2 s/epoch, 1 worker (epochs ≥ 1) | [11.943 [11.74–12.899], n=6](/docs/results/results.csv#L117) | [12.119 [11.881–12.341], n=6](/docs/results/results.csv#L105) | [11.909 [11.829–12.071], n=6](/docs/results/results.csv#L111) |
| M2 s/epoch, 2 workers (epochs ≥ 1) | [11.086 [10.749–11.177], n=6](/docs/results/results.csv#L120) | [8.007 [7.54–8.182], n=6](/docs/results/results.csv#L108) | [7.526 [7.296–7.737], n=6](/docs/results/results.csv#L114) |
| M2 ratio 2 workers / 1 worker | [0.928](/docs/results/results.csv#L195) | [0.661](/docs/results/results.csv#L196) | [0.632](/docs/results/results.csv#L197) |
| M3 kill one worker: time to resume, s | [12.811 [12.439–13.163], n=3](/docs/results/results.csv#L156) | [8.263 [8.032–8.459], n=3](/docs/results/results.csv#L150) | [6.695 [6.34–6.851], n=3](/docs/results/results.csv#L153) |
| M3 kill one worker: steps lost | [25 [15–35], n=3](/docs/results/results.csv#L147) | [55 [25–55], n=3](/docs/results/results.csv#L141) | [45 [35–55], n=3](/docs/results/results.csv#L144) |
| D1 kill one worker: outcome | [pass=3](/docs/results/results.csv#L4) | [pass=3](/docs/results/results.csv#L2) | [pass=3](/docs/results/results.csv#L3) |
| D2 preemption: outcome | admin-requeue: [pass=3](/docs/results/results.csv#L8)<br>usr1-trap: [pass=3](/docs/results/results.csv#L9) | [pass=3](/docs/results/results.csv#L5) | admin-requeue: [pass=3](/docs/results/results.csv#L6)<br>usr1-trap: [pass=3](/docs/results/results.csv#L7) |
| D2 preemption: time to resume, s | admin-requeue: [178.683 [164.033–192.286], n=3](/docs/results/results.csv#L49)<br>usr1-trap: [164.448 [157.526–179.825], n=3](/docs/results/results.csv#L52) | [63.393 [63.315–64.725], n=3](/docs/results/results.csv#L40) | admin-requeue: [156.654 [152.517–158.343], n=3](/docs/results/results.csv#L43)<br>usr1-trap: [182.257 [174.198–194.847], n=3](/docs/results/results.csv#L46) |
| M4 two jobs at once: outcome | a: [both-failed=3](/docs/results/results.csv#L184)<br>b: [serialized=3](/docs/results/results.csv#L185)<br>c: [both-concurrent=3](/docs/results/results.csv#L186) | [both-concurrent=3](/docs/results/results.csv#L180) | a: [both-failed=3](/docs/results/results.csv#L181)<br>b: [serialized=3](/docs/results/results.csv#L182)<br>c: [both-concurrent=3](/docs/results/results.csv#L183) |
| M4 two jobs at once: makespan, s | a: [1131.113 [842.652–1195.275], n=3](/docs/results/results.csv#L171)<br>b: [234.524 [234.506–234.713], n=3](/docs/results/results.csv#L174)<br>c: [75.252 [43.244–75.258], n=3](/docs/results/results.csv#L177) | [75.283 [74.282–75.4], n=3](/docs/results/results.csv#L159) | a: [1131.206 [843.6–1132.1], n=3](/docs/results/results.csv#L162)<br>b: [235.542 [235.531–235.563], n=3](/docs/results/results.csv#L165)<br>c: [43.201 [43.199–75.26], n=3](/docs/results/results.csv#L168) |

_All results come from CPU-only containers on **one** machine, where both "nodes" share the same physical CPUs, memory and disk. They compare how the schedulers launch, recover and share a Ray job. They say nothing about hardware speed, network fabrics or multi-node scaling._

Host: `AMD EPYC 7763 64-Core Processor; 4 cpu; 15 GiB; Ubuntu 24.04.5 LTS; x86_64`. Raw data: [`docs/results/raw/`](/docs/results/raw/), generated by `make bench`. D2 configs: `usr1-trap`, `admin-requeue` (Slurm and Slinky), `head-pod-delete` (KubeRay). M4 configs: (a) default, (b) `--exclusive`, (c) per-job ports, (k) two RayJobs.
<!-- results:end -->

## Quickstart

Needs Docker (Compose v2+, ≥ 6 GiB memory), GNU make, bash and git. The KubeRay and Slinky sides also need kind v0.33, kubectl v1.37 and helm v3.22 (`sudo bash scripts/install-k8s-tools.sh` installs the pinned versions on Linux amd64).

```bash
# Ray on Slurm (Docker Compose: controller + 2 compute nodes)
make up && make train-slurm && make verify

# Ray on Kubernetes (KubeRay RayJob on kind)
make train-k8s && make verify SCHED=k8s

# Slurm on Kubernetes (Slinky, in the same kind cluster)
make up-slinky && make train-slinky && make verify SCHED=slinky

# Prometheus + Grafana (http://127.0.0.1:3000/d/rsk)
make metrics-up

make down   # remove everything
```

`make verify` prints `PASS` for each check, then `verify <run>: PASS`:
C1 job succeeded · C2 `run.json` finished · C3 one checkpoint per epoch · C4 2 workers on 2 nodes · C5 launcher log shows head and worker · C6 same `train.py` bytes on every scheduler.

Common variables: `EPOCHS`, `WORKERS`, `DATA=synthetic|fashion-mnist`, `LAUNCHER=symmetric|manual|requeue`, `EXCLUSIVE=1`, `RUN=<name>` (rerunning a finished `RUN` with more epochs resumes it from its last checkpoint).

Tested on Linux (GitHub Actions, amd64 and arm64 for Slurm). The Slurm side was also run on Windows 11 through WSL2. macOS is untested.

## How it works

```mermaid
flowchart LR
  subgraph slurm["Slurm in Docker Compose"]
    ctld["slurmctld<br/>sbatch"] -->|"allocates 2 nodes"| s1["c1: ray symmetric-run<br/>Ray head + driver train.py"]
    ctld --> s2["c2: ray symmetric-run<br/>Ray worker node"]
    s2 -->|"joins GCS :6379"| s1
  end
  subgraph kind["KubeRay on kind"]
    op["KubeRay operator"] -->|"RayJob → RayCluster"| head["head pod<br/>driver train.py"]
    op --> wk["worker pod"]
    op --> sub["submitter pod<br/>ray job submit"]
    wk -->|"joins GCS"| head
  end
  subgraph slinky["Slinky on the same kind node"]
    sop["slurm-operator"] -->|"NodeSet cpu"| p1["slurmd pod cpu-0<br/>ray symmetric-run, head + driver"]
    sop --> p2["slurmd pod cpu-1<br/>ray symmetric-run, worker"]
    login["login pod<br/>sbatch"] --> p1
    p2 -->|"joins GCS :6379"| p1
  end
  s1 -.->|"/data/ray_results"| vol[("shared volume")]
  head -.->|"/data/ray_results"| hp[("hostPath on the kind node")]
  p1 -.->|"/data/ray_results"| hp
```

- **Slurm:** `sbatch` gets 2 nodes; `ray symmetric-run` starts the Ray head on the first and a worker on the second, then runs `train.py` on the head.
- **KubeRay:** a RayJob creates a head pod, a worker pod and a submitter pod that runs `ray job submit`.
- **Slinky:** SchedMD's slurm-operator runs Slurm as pods; the same sbatch file runs unchanged.

On all three, Ray Train spreads 2 workers over the 2 nodes (DDP over gloo), and rank 0 writes a checkpoint to shared storage every epoch.

## Failure drills

Run with `make drill-kill-worker|drill-preempt|drill-two-jobs SCHED=slurm|k8s|slinky`; results are in the table above, raw CSVs in [docs/results/raw/](docs/results/raw/), and the surprises behind them in [docs/NOTES.md](docs/NOTES.md).

- **D1 kill a worker:** `pkill -9` one Ray Train worker; the job must restore its last checkpoint and succeed.
- **D2 preemption:** Slurm USR1 trap → `scontrol requeue` (and a direct requeue); KubeRay deletes the head pod. The run must resume and succeed.
- **D3 two jobs at once:** default, `--exclusive` and per-job Ray ports on Slurm; two RayJobs on KubeRay.

`make bench` reruns everything and regenerates the table; CI fails if the README table differs from the raw data.

## Repository layout

```
Makefile, versions.env   the single interface; every pinned version and digest
train/                   the one workload (train.py + hash-locked requirements)
slurm/, slinky/          Slurm node images, Compose cluster, sbatch launchers
k8s/                     Ray image, kind config, RayJob, Slinky values, monitoring manifests
observability/           Prometheus configs and the Grafana dashboard
scripts/, drills/, bench/  make targets, failure drills, benchmarks
docs/                    when-to-use-which.md, NOTES.md, results/
```

## Limits

A CPU-only lab on one machine: both "nodes" share the same CPUs, memory and disk, so it compares how schedulers launch, recover and share a Ray job, not hardware speed or scaling. No GPU, cloud, HA, TLS or multi-user auth; jobs run as root in privileged containers, so do not run it on shared machines. Synthetic data has random labels: it tests the plumbing, not the model.

## Status

- **v0.1** Ray on Slurm, verified in CI
- **v0.2** KubeRay, three failure drills, measured results and the guide
- **v0.3** Slinky as a third scheduler; Prometheus and Grafana for all three
- **Next (optional):** one documented GPU run, outside CI and the results table

## Credits and license

The Slurm cluster is derived from [giovtorres/slurm-docker-cluster](https://github.com/giovtorres/slurm-docker-cluster) (MIT); see [NOTICE](NOTICE). Built on [Ray](https://github.com/ray-project/ray), [KubeRay](https://github.com/ray-project/kuberay), [Slinky](https://github.com/SlinkyProject/slurm-operator), [kind](https://github.com/kubernetes-sigs/kind), [Prometheus](https://prometheus.io), [Grafana](https://grafana.com) and [PyTorch](https://pytorch.org). Licensed under [Apache-2.0](LICENSE).
