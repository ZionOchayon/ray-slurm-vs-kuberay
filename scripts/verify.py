"""Check a Slurm training run from its artifacts, not only from its job state.

Runs inside the slurmctld container (`make verify`). Checks C1-C5 from docs/SPEC.md FR-08.
Exit: 0 all checks pass, 1 any check fails, 2 invalid arguments.
"""

import argparse
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


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--run", required=True)
    p.add_argument("--job-id", required=True)
    p.add_argument("--storage", default="/data/ray_results")
    p.add_argument("--log-dir", default="/data/logs")
    a = p.parse_args()
    if not RUN_RE.fullmatch(a.run) or not a.job_id.isdigit():
        p.error("--run must match the RUN pattern and --job-id must be numeric")

    run_dir = Path(a.storage) / a.run
    results: list[tuple[str, bool, str]] = []

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
    ckpts = sorted(run_dir.glob("checkpoint_epoch_*"))
    missing = [c.name for c in ckpts if not (c / "model.pt").is_file()]
    results.append(
        (
            "C3 one checkpoint per epoch",
            epochs is not None and len(ckpts) == epochs and not missing,
            f"expected={epochs} found={[c.name for c in ckpts]} missing_model_pt={missing}",
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

    log = Path(a.log_dir) / f"{a.run}-{a.job_id}.out"
    try:
        text = log.read_text(errors="replace")
    except OSError as e:
        results.append(("C5 symmetric-run head + worker", False, str(e)))
    else:
        heads, workers = text.count("On head node."), text.count("On worker node.")
        results.append(
            (
                "C5 symmetric-run head + worker",
                heads == 1 and workers == 1,
                f"head={heads} worker={workers} log={log}",
            )
        )

    for name, ok, detail in results:
        print(f"{'PASS' if ok else 'FAIL'} {name}: {detail}")
    failed = sum(not ok for _, ok, _ in results)
    print(f"verify {a.run}: {'PASS' if not failed else f'FAIL ({failed} check(s))'}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
