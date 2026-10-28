"""Turn docs/results/raw/*.csv into docs/results/results.csv, docs/results/table.md and the README block.

For each (kind, scheduler), only the newest raw file is used (raw files are named
<kind>-<scheduler>-<UTC timestamp>.csv). Every number in the table comes from these files.
--check README.md exits 1 if the README block differs from the generated table, or if a metric or
drill has no data for a scheduler (SC-04, SC-06). Standard library only; runs in any project image.
Exit: 0 ok, 1 check failed, 2 invalid arguments.
"""

import argparse
import csv
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESULTS = ROOT / "docs" / "results"
RAW = RESULTS / "raw"
START, END = "<!-- results:start -->", "<!-- results:end -->"
SCHEDS = {
    "slurm": "Slurm (ray symmetric-run)",
    "k8s": "KubeRay (RayJob on kind)",
    "slinky": "Slurm on K8s (Slinky)",
}
FILE_RE = re.compile(r"(?P<kind>.+)-(?P<sched>slurm|k8s|slinky)-(?P<ts>\d{8}T\d{6}Z)\.csv")
# Required for SC-06: every metric and drill on both schedulers.
REQUIRED = {
    "M1": "M1_submit_to_first_step_s",
    "M2": "M2_epoch_train_s",
    "M3": "M3_time_to_resume_s",
    "M4": "M4_outcome",
    "D1": "D1_outcome",
    "D2": "D2_outcome",
    "D3": "M4_outcome",
}
HONESTY = (
    "All results come from CPU-only containers on **one** machine, where both \"nodes\" share the same "
    "physical CPUs, memory and disk. They compare how the schedulers launch, recover and share a Ray "
    "job. They say nothing about hardware speed, network fabrics or multi-node scaling."
)


def latest_raw_files() -> dict[tuple[str, str], Path]:
    newest: dict[tuple[str, str], Path] = {}
    for f in sorted(RAW.glob("*.csv")):
        m = FILE_RE.fullmatch(f.name)
        if m:
            newest[(m["kind"], m["sched"])] = f  # sorted, so the last one is the newest
    return newest


def load_rows(files) -> list[dict]:
    rows = []
    for f in files.values():
        with f.open(newline="") as fh:
            for r in csv.DictReader(fh):
                r["source"] = f.name
                rows.append(r)
    return rows


def num(v: str):
    try:
        return float(v)
    except ValueError:
        return None


def summarize(rows: list[dict]) -> list[dict]:
    groups = defaultdict(list)
    for r in rows:
        groups[(r["metric"], r["scheduler"], r["config"])].append(r)
    out = []
    for (metric, sched, config), rs in sorted(groups.items()):
        unit, source = rs[0]["unit"], rs[0]["source"]
        base = {"metric": metric, "scheduler": sched, "config": config, "unit": unit, "source": source}
        if unit in ("outcome", "text", "code", "bool"):
            if metric.startswith("D3_job"):
                continue  # per-job detail stays in the raw file
            counts = defaultdict(int)
            for r in rs:
                counts[r["value"]] += 1
            value = ";".join(f"{k}={v}" for k, v in sorted(counts.items()))
            if len(counts) > 1 and metric == "M4_outcome":
                value += ";flaky"
            out.append({**base, "stat": "counts", "value": value, "n": len(rs)})
            continue
        vals = [v for v in (num(r["value"]) for r in rs) if v is not None]
        missing = len(rs) - len(vals)
        if not vals:
            out.append({**base, "stat": "N/A", "value": f"no value in {len(rs)} rep(s)", "n": 0})
            continue
        stats = [("median", statistics.median(vals)), ("min", min(vals)), ("max", max(vals))]
        if metric == "NFR04_peak_mem_mib":
            stats = [("peak", max(vals))]
        for stat, v in stats:
            out.append({**base, "stat": stat, "value": f"{v:.3f}".rstrip("0").rstrip("."), "n": len(vals)})
        if missing:
            out.append({**base, "stat": "missing", "value": str(missing), "n": len(rs)})
    # M2: ratio of the median epoch time with 2 workers to 1 worker.
    for sched in SCHEDS:
        med = {
            r["config"]: num(r["value"])
            for r in out
            if r["metric"] == "M2_epoch_train_s" and r["scheduler"] == sched and r["stat"] == "median"
        }
        if med.get("w1") and med.get("w2") is not None:
            src = next(r["source"] for r in out if r["metric"] == "M2_epoch_train_s" and r["scheduler"] == sched)
            out.append({"metric": "M2_ratio_w2_over_w1", "scheduler": sched, "config": "w2/w1",
                        "unit": "ratio", "source": src, "stat": "median_ratio",
                        "value": f"{med['w2'] / med['w1']:.3f}", "n": 1})  # fmt: skip
    for i, r in enumerate(out, start=2):  # line 1 is the header
        r["line"] = i
    return out


def missing_required(results: list[dict]) -> list[str]:
    have = {(r["metric"], r["scheduler"]) for r in results if r["stat"] != "N/A"}
    return [f"{name} {s}" for name, metric in REQUIRED.items() for s in SCHEDS if (metric, s) not in have]


def cell(results, metric, sched, config=None, fmt="{median} [{min}–{max}], n={n}") -> str:
    rs = [r for r in results if r["metric"] == metric and r["scheduler"] == sched
          and (config is None or r["config"] == config)]  # fmt: skip
    if not rs:
        return "N/A (not measured)"
    parts = []
    for cfg in sorted({r["config"] for r in rs}):
        by = {r["stat"]: r for r in rs if r["config"] == cfg}
        if "counts" in by:
            text = by["counts"]["value"].replace(";", ", ")
            row = by["counts"]
        elif "median" in by:
            text = fmt.format(median=by["median"]["value"], min=by["min"]["value"],
                              max=by["max"]["value"], n=by["median"]["n"])  # fmt: skip
            row = by["median"]
        elif "median_ratio" in by:
            text, row = by["median_ratio"]["value"], by["median_ratio"]
        else:
            row = next(iter(by.values()))
            text = f"N/A ({row['value']})"
        link = f"[{text}](/docs/results/results.csv#L{row['line']})"
        parts.append(link if config is not None or len({r["config"] for r in rs}) == 1 else f"{cfg}: {link}")
    return "<br>".join(parts)


def table(results: list[dict]) -> str:
    rows = [
        ("M1 submit → first step, s: median [min–max]", "M1_submit_to_first_step_s", None),
        ("M2 s/epoch, 1 worker (epochs ≥ 1)", "M2_epoch_train_s", "w1"),
        ("M2 s/epoch, 2 workers (epochs ≥ 1)", "M2_epoch_train_s", "w2"),
        ("M2 ratio 2 workers / 1 worker", "M2_ratio_w2_over_w1", None),
        ("M3 kill one worker: time to resume, s", "M3_time_to_resume_s", None),
        ("M3 kill one worker: steps lost", "M3_steps_lost", None),
        ("D1 kill one worker: outcome", "D1_outcome", None),
        ("D2 preemption: outcome", "D2_outcome", None),
        ("D2 preemption: time to resume, s", "D2_time_to_resume_s", None),
        ("M4 two jobs at once: outcome", "M4_outcome", None),
        ("M4 two jobs at once: makespan, s", "M4_makespan_s", None),
    ]
    lines = ["| Metric | " + " | ".join(SCHEDS.values()) + " |", "| --- " * (len(SCHEDS) + 1) + "|"]
    for label, metric, config in rows:
        cells = " | ".join(cell(results, metric, sched, config) for sched in SCHEDS)
        lines.append(f"| {label} | {cells} |")
    hosts = sorted({r["host_profile"] for r in load_rows(latest_raw_files())})
    lines += [
        "",
        f"_{HONESTY}_",
        "",
        "Host: " + " · ".join(f"`{h}`" for h in hosts) + ". Raw data: [`docs/results/raw/`](/docs/results/raw/), "
        "generated by `make bench`. D2 configs: `usr1-trap`, `admin-requeue` (Slurm and Slinky), `head-pod-delete` "
        "(KubeRay). M4 configs: (a) default, (b) `--exclusive`, (c) per-job ports, (k) two RayJobs.",
    ]
    return "\n".join(lines) + "\n"


def readme_block(readme: str) -> str:
    if START not in readme or END not in readme:
        raise SystemExit(f"README has no {START} ... {END} block")
    return readme.split(START, 1)[1].split(END, 1)[0].strip("\n") + "\n"


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--check", metavar="README", type=Path, help="only check; write nothing")
    p.add_argument("--readme", type=Path, default=ROOT / "README.md")
    a = p.parse_args()

    files = latest_raw_files()
    results = summarize(load_rows(files))
    md = table(results)
    missing = missing_required(results)

    if a.check:
        ok = True
        if readme_block(a.check.read_text()) != md:
            print(f"FAIL {a.check} results block differs from the generated table (run make bench)")
            ok = False
        for m in missing:
            print(f"FAIL no data: {m}")
            ok = False
        print("summarize --check:", "PASS" if ok else "FAIL")
        return 0 if ok else 1

    fields = ["metric", "scheduler", "config", "stat", "value", "unit", "n", "source"]
    with (RESULTS / "results.csv").open("w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=fields, extrasaction="ignore", lineterminator="\n")
        w.writeheader()
        w.writerows(results)
    (RESULTS / "table.md").write_text(md)
    readme = a.readme.read_text()
    a.readme.write_text(readme.split(START)[0] + START + "\n" + md + END + readme.split(END, 1)[1])
    print(f"wrote {RESULTS / 'results.csv'} ({len(results)} rows), {RESULTS / 'table.md'}, {a.readme}")
    for m in missing:
        print(f"warning: no data: {m}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
