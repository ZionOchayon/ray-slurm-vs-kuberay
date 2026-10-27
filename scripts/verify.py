"""Check a training run from its artifacts, not only from its job state.

Runs inside the slurmctld container (`make verify`), or with --no-slurm inside the K8s image
(`make verify SCHED=k8s`). Checks C1-C6 from docs/SPEC.md FR-08.
Exit: 0 all checks pass, 1 any check fails, 2 invalid arguments.
"""

import argparse
import hashlib
import json
import re
import subprocess
import sys
import time
from pathlib import Path

RUN_RE = re.compile(r"[a-z0-9]([a-z0-9-]{0,40}[a-z0-9])?")
UNFINISHED = {"", "PENDING", "RUNNING", "COMPLETING", "REQUEUED"}


def sacct_state(job_id: str, wait_s: int = 30) -> str:
    """Return 'STATE|EXITCODE', retrying while accounting still shows the job as unfinished."""
    deadline = time.monotonic() + wait_s
    while True:
        out = subprocess.run(
            ["sacct", "-n", "-X", "-P", "-j", job_id, "-o", "State,ExitCode"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        if out.split("|")[0] not in UNFINISHED or time.monotonic() > deadline:
            return out
        time.sleep(2)


def check_launcher_log(launcher: str, text: str, log: Path) -> tuple[str, bool, str]:
    """C5: the job script really started Ray the way its launcher says."""
    heads, workers = text.count("On head node."), text.count("On worker node.")
    if launcher == "manual":
        n = text.count("ray-manual port map:")
        return ("C5 manual launcher port map", n == 1, f"port_map_lines={n} log={log}")
    if launcher == "requeue":
        # The requeue script appends to its log, so every attempt adds one head and one worker line.
        ok = heads >= 1 and heads == workers
        return ("C5 requeue head + worker per attempt", ok, f"head={heads} worker={workers} log={log}")
    ok = heads == 1 and workers == 1
    return ("C5 symmetric-run head + worker", ok, f"head={heads} worker={workers} log={log}")


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--run", required=True)
    p.add_argument("--job-id", help="Slurm job ID (required unless --no-slurm)")
    p.add_argument("--storage", default="/data/ray_results")
    p.add_argument("--log-dir", default="/data/logs")
    p.add_argument("--launcher", choices=["symmetric", "manual", "requeue"], default="symmetric")
    p.add_argument("--train-py", default="/opt/rayslurm/train/train.py", help="file C6 hashes")
    p.add_argument("--no-slurm", action="store_true", help="K8s run: no sacct, no Slurm job log")
    p.add_argument("--job-state", default="", help="with --no-slurm: final RayJob jobStatus")
    a = p.parse_args()
    if not RUN_RE.fullmatch(a.run):
        p.error("--run must match the RUN pattern")
    if not a.no_slurm and not (a.job_id or "").isdigit():
        p.error("--job-id must be numeric (or pass --no-slurm)")

    run_dir = Path(a.storage) / a.run
    results: list[tuple[str, bool, str]] = []

    if a.no_slurm:
        results.append(
            ("C1 RayJob SUCCEEDED", a.job_state == "SUCCEEDED", f"jobStatus={a.job_state or '?'}")
        )
    else:
        state = sacct_state(a.job_id)
        results.append(("C1 job COMPLETED, exit 0:0", state == "COMPLETED|0:0", state))

    run_json = {}
    try:
        run_json = json.loads((run_dir / "run.json").read_text())
    except (OSError, ValueError) as e:
        results.append(("C2 run.json finished", False, str(e)))
    else:
        status = run_json.get("status")
        results.append(
            ("C2 run.json finished", status == "finished", f"status={status}")
        )

    epochs = run_json.get("epochs")
    ckpts = sorted(c.name for c in run_dir.glob("checkpoint_epoch_*"))
    missing = [c for c in ckpts if not (run_dir / c / "model.pt").is_file()]
    # Contiguous: exactly checkpoint_epoch_000 .. epochs-1, so a resumed run has no gaps.
    expected = [f"checkpoint_epoch_{i:03d}" for i in range(epochs or 0)]
    results.append(
        (
            "C3 one checkpoint per epoch",
            epochs is not None and ckpts == expected and not missing,
            f"expected={epochs} found={ckpts} missing_model_pt={missing}",
        )
    )

    ips = run_json.get("worker_node_ips") or []
    two_workers = run_json.get("workers") == 2
    results.append(
        (
            "C4 2 workers on 2 distinct nodes",
            (len(set(ips)) == 2) if two_workers else True,
            f"workers={run_json.get('workers')} worker_node_ips={ips}",
        )
    )

    if a.no_slurm:
        results.append(("C5 launcher log", True, "n/a on K8s (KubeRay starts Ray, not a job script)"))
    else:
        log = Path(a.log_dir) / f"{a.run}-{a.job_id}.out"
        try:
            text = log.read_text(errors="replace")
        except OSError as e:
            results.append((f"C5 {a.launcher} launcher log", False, str(e)))
        else:
            results.append(check_launcher_log(a.launcher, text, log))

    try:
        want = hashlib.sha256(Path(a.train_py).read_bytes()).hexdigest()
    except OSError as e:
        results.append(("C6 same train.py bytes", False, str(e)))
    else:
        got = run_json.get("train_py_sha256")
        results.append(
            ("C6 same train.py bytes", got == want, f"run={got} file={want} ({a.train_py})")
        )

    for name, ok, detail in results:
        print(f"{'PASS' if ok else 'FAIL'} {name}: {detail}")
    failed = sum(not ok for _, ok, _ in results)
    print(f"verify {a.run}: {'PASS' if not failed else f'FAIL ({failed} check(s))'}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
