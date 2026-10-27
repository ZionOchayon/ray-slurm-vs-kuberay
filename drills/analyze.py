"""Read a run's events.jsonl and print key=value lines for the drill and bench scripts.

Runs inside a container that sees the run's /data (slurmctld, or the K8s image with .data/k8s
mounted), so the host needs no Python. Event schema: docs/SPEC.md §9.5.
Exit: 0 ok, 1 the events do not contain what the command needs, 2 invalid arguments.
"""

import argparse
import json
import sys
from pathlib import Path


def load(run_dir: Path) -> list[dict]:
    lines = (run_dir / "events.jsonl").read_text().splitlines()
    return [json.loads(line) for line in lines if line.strip()]


def first(events, event, after=float("-inf"), **match):
    for e in events:
        if e["event"] == event and e["ts"] > after and all(e.get(k) == v for k, v in match.items()):
            return e
    return None


def last(events, event, before=float("inf")):
    hits = [e for e in events if e["event"] == event and e["ts"] < before]
    return hits[-1] if hits else None


def cmd_resume(events, a) -> int:
    """M3 / D2: recovery after an injection at --since (a timestamp from the same clock).

    time_to_resume_s: first first_step after the restore minus the injection time.
    steps_lost: last global_step logged before the restore minus the restored global_step.
    expected_epoch: the last epoch_end before the restore, i.e. the newest checkpoint.
    """
    restored = first(events, "restored", after=a.since)
    if restored is None:
        print("error=no restored event after the injection")
        return 1
    resumed = first(events, "first_step", after=restored["ts"])
    # Work done before the restore, not before the injection: a pod being deleted keeps training
    # through its termination grace period, and those steps count as done (then lost, or kept).
    ckpt = last(events, "epoch_end", before=restored["ts"])
    progress = last(events, "progress", before=restored["ts"])
    lost_from = max(e["global_step"] for e in (ckpt, progress) if e) if (ckpt or progress) else 0
    print(f"restored_epoch={restored['epoch']}")
    print(f"expected_epoch={ckpt['epoch'] if ckpt else 'none'}")
    print(f"time_to_resume_s={resumed['ts'] - a.since:.3f}" if resumed else "time_to_resume_s=")
    print(f"steps_lost={lost_from - restored['global_step']}")
    print(f"restart_count={max(e['restart_count'] for e in events)}")
    epoch0 = first(events, "epoch_end", epoch=0)
    print(f"steps_per_epoch={epoch0['global_step'] if epoch0 else ''}")
    return 0 if resumed else 1


def cmd_m1(events, a) -> int:
    start = first(events, "driver_start", restart_count=0)
    step = first(events, "first_step", restart_count=0)
    if not (start and step):
        print("error=no driver_start/first_step with restart_count 0")
        return 1
    print(f"submit_to_first_step_s={step['ts'] - a.submit_ts:.3f}")
    print(f"submit_to_driver_start_s={start['ts'] - a.submit_ts:.3f}")
    print(f"driver_start_to_first_step_s={step['ts'] - start['ts']:.3f}")
    return 0


def cmd_m2(events, a) -> int:
    ends = [e for e in events if e["event"] == "epoch_end"]
    for e in ends:
        print(f"epoch={e['epoch']} epoch_train_s={e['epoch_train_s']:.3f} ckpt_s={e['ckpt_s']:.3f}")
    try:
        threads = json.loads((a.run_dir / "run.json").read_text()).get("torch_num_threads")
    except (OSError, ValueError):
        threads = None
    print(f"torch_num_threads={threads if threads is not None else ''}")
    return 0 if ends else 1


def cmd_span(events, a) -> int:
    start, end = first(events, "driver_start"), last(events, "run_end")
    print(f"start_ts={start['ts'] if start else ''}")
    print(f"end_ts={end['ts'] if end else ''}")
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("command", choices=["resume", "m1", "m2", "span"])
    p.add_argument("--run-dir", type=Path, required=True)
    p.add_argument("--since", type=float, help="resume: injection timestamp")
    p.add_argument("--submit-ts", type=float, help="m1: submission timestamp")
    a = p.parse_args()
    if a.command == "resume" and a.since is None or a.command == "m1" and a.submit_ts is None:
        p.error("resume needs --since; m1 needs --submit-ts")
    try:
        events = load(a.run_dir)
    except OSError as e:
        print(f"error={e}")
        return 1
    return {"resume": cmd_resume, "m1": cmd_m1, "m2": cmd_m2, "span": cmd_span}[a.command](events, a)


if __name__ == "__main__":
    sys.exit(main())
