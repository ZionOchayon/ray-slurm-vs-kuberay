"""Turn docs/results/raw/*.csv into docs/results/results.csv, table.md, the chart SVGs and the README block.

For each (kind, scheduler), only the newest raw file is used (raw files are named
<kind>-<scheduler>-<UTC timestamp>.csv). Every number in the table and charts comes from these files.
--check README.md exits 1 if the README block, table.md or a chart differs from what the data
generates, or if a metric or drill has no data for a scheduler. Standard library only; runs in any
project image.
Exit: 0 ok, 1 check failed, 2 invalid arguments.
"""

import argparse
import csv
import math
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
# Required: every metric and drill on every scheduler.
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
    lines += [
        "",
        f"_{HONESTY}_",
        "",
        host_line() + " D2 configs: `usr1-trap`, `admin-requeue` (Slurm and Slinky), `head-pod-delete` "
        "(KubeRay). M4 configs: (a) default, (b) `--exclusive`, (c) per-job ports, (k) two RayJobs.",
    ]
    return "\n".join(lines) + "\n"


def host_line() -> str:
    hosts = sorted({r["host_profile"] for r in load_rows(latest_raw_files())})
    return (
        "Host: " + " · ".join(f"`{h}`" for h in hosts) + ". Raw data: [`docs/results/raw/`](/docs/results/raw/), "
        "generated by `make bench`."
    )


# Charts: one SVG per question, drawn from the same summary rows as the table.
CHART_COLOR = {"slurm": "#3d6fd6", "k8s": "#e07b28", "slinky": "#2a9d7c"}
CHART_NAME = {"slurm": "Slurm", "k8s": "KubeRay", "slinky": "Slinky"}
CHART_STYLE = (
    "text{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;fill:#1f2328}"
    ".t{font-size:16px;font-weight:600}.n,.v,.l,.k{font-size:12px}.n,.k,.m{fill:#59636e}.k{font-size:11px}"
    ".grid{stroke:#d1d9e0}.rng{stroke:#59636e;stroke-width:1.5}.bad{fill:#cf222e}"
    "@media (prefers-color-scheme:dark){text{fill:#f0f6fc}.n,.k,.m{fill:#9198a1}.grid{stroke:#3d444d}"
    ".rng{stroke:#9198a1}.bad{fill:#ff7b72}}"
)


def stat_row(results, metric, sched, config, stat):
    for r in results:
        if (r["metric"], r["scheduler"], r["config"], r["stat"]) == (metric, sched, config, stat):
            return r
    return None


def outcome_text(results, metric, sched, config) -> str:
    """'pass=3' → '3/3 passed'; 'both-failed=3' → 'both failed 3/3'."""
    r = stat_row(results, metric, sched, config, "counts")
    if r is None:
        return ""
    parts = []
    for p in r["value"].split(";"):
        k, _, v = p.partition("=")
        parts.append(k if not v else f"{v}/{r['n']} passed" if k == "pass" else f"{k.replace('-', ' ')} {v}/{r['n']}")
    return ", ".join(parts)


def chart_row(results, label, metric, sched, config, outcome=None, split=None):
    """A bar at the median with a min–max line; `split` stacks two medians that make up the bar."""
    med, lo, hi = (stat_row(results, metric, sched, config, s) for s in ("median", "min", "max"))
    if med is None or lo is None or hi is None:
        return None
    total = float(med["value"])
    segs = [(total, 1.0)]
    if split:
        a, b = (stat_row(results, m, sched, config, "median") for m in split)
        if a and b:
            segs = [(float(a["value"]), 1.0), (float(b["value"]), 0.5)]
    tag = outcome_text(results, outcome, sched, config) if outcome else ""
    return {"label": label, "color": CHART_COLOR[sched], "segs": segs, "total": total,
            "lo": float(lo["value"]), "hi": float(hi["value"]), "tag": tag, "bad": "failed" in tag}  # fmt: skip


def nice_ticks(xmax: float) -> list[float]:
    raw = xmax / 5
    mag = 10 ** math.floor(math.log10(raw))
    step = next(m * mag for m in (1, 2, 2.5, 5, 10) if m * mag >= raw)
    return [i * step for i in range(math.ceil(xmax / step) + 1)]


def fmt_s(v: float) -> str:
    return f"{v:.0f}" if v >= 100 else f"{v:.1f}"


def svg_chart(title: str, note: str, rows: list[dict | None]) -> str:
    esc = lambda s: s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")  # noqa: E731
    rows = [r for r in rows if r]
    char = 6.4  # shortcut: estimated px per character at 12px; exact text widths need a browser
    W, top, row_h, axis_h = 760, 64, 32, 26
    left = 16 + char * max(len(r["label"]) for r in rows) + 12
    end = max(len(f"{fmt_s(r['total'])} s") + (len(r["tag"]) + 2 if r["tag"] else 0) for r in rows)
    right = W - 16 - char * end - 8
    ticks = nice_ticks(max(max(r["hi"], r["total"]) for r in rows))
    x = lambda v: left + (right - left) * v / ticks[-1]  # noqa: E731
    H = top + len(rows) * row_h + axis_h
    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" role="img" '
        f'aria-label="{esc(title)}">',
        f"<title>{esc(title)}</title><style>{CHART_STYLE}</style>",
        f'<text class="t" x="16" y="24">{esc(title)}</text>',
        f'<text class="n" x="16" y="44">{esc(note)}</text>',
    ]
    for t in ticks:
        out.append(f'<line class="grid" x1="{x(t):.1f}" x2="{x(t):.1f}" y1="{top - 4}" y2="{H - axis_h + 4}"/>')
        unit = " s" if t == ticks[-1] else ""
        out.append(f'<text class="k" x="{x(t):.1f}" y="{H - 8}" text-anchor="middle">{t:g}{unit}</text>')
    for i, r in enumerate(rows):
        cy = top + i * row_h + row_h / 2
        out.append(f'<text class="l" x="{left - 12:.1f}" y="{cy + 4:.1f}" text-anchor="end">{esc(r["label"])}</text>')
        acc = 0.0
        for v, opacity in r["segs"]:
            w = max(1.0, x(acc + v) - x(acc))
            out.append(f'<rect x="{x(acc):.1f}" y="{cy - 8:.1f}" width="{w:.1f}" height="16" rx="2" '
                       f'fill="{r["color"]}" fill-opacity="{opacity}"/>')  # fmt: skip
            acc += v
        out.append(f'<line class="rng" x1="{x(r["lo"]):.1f}" x2="{x(r["hi"]):.1f}" y1="{cy:.1f}" y2="{cy:.1f}"/>')
        for v in (r["lo"], r["hi"]):
            out.append(f'<line class="rng" x1="{x(v):.1f}" x2="{x(v):.1f}" y1="{cy - 5:.1f}" y2="{cy + 5:.1f}"/>')
        vx = x(max(r["total"], r["hi"])) + 6
        text = f"{fmt_s(r['total'])} s"
        out.append(f'<text class="v" x="{vx:.1f}" y="{cy + 4:.1f}">{text}</text>')
        if r["tag"]:
            cls = "v bad" if r["bad"] else "v m"
            out.append(f'<text class="{cls}" x="{vx + char * (len(text) + 2):.1f}" y="{cy + 4:.1f}">{esc(r["tag"])}</text>')
    out.append("</svg>")
    return "\n".join(out) + "\n"


def charts(results: list[dict]) -> dict[str, str]:
    S = list(SCHEDS)
    startup = [
        chart_row(results, CHART_NAME[s], "M1_submit_to_first_step_s", s, "warm",
                  split=("M1_submit_to_driver_start_s", "M1_driver_start_to_first_step_s"))  # fmt: skip
        for s in S
    ]
    kill = [chart_row(results, f"Worker killed · {CHART_NAME[s]}", "M3_time_to_resume_s", s, "default", "D1_outcome")
            for s in S]  # fmt: skip
    preempt = [
        chart_row(results, label, "D2_time_to_resume_s", s, c, "D2_outcome")
        for s, c, label in [
            ("slurm", "usr1-trap", "Preempted · Slurm, USR1 trap"),
            ("slurm", "admin-requeue", "Preempted · Slurm, admin requeue"),
            ("slinky", "usr1-trap", "Preempted · Slinky, USR1 trap"),
            ("slinky", "admin-requeue", "Preempted · Slinky, admin requeue"),
            ("k8s", "head-pod-delete", "Preempted · KubeRay, head pod deleted"),
        ]
    ]
    cfg = {"a": "default", "b": "--exclusive", "c": "per-job Ray ports", "k": "two RayJobs"}
    two = [
        chart_row(results, f"{CHART_NAME[s]}, {cfg[c]}", "M4_makespan_s", s, c, "M4_outcome")
        for s, c in [("slurm", "a"), ("slurm", "b"), ("slurm", "c"), ("slinky", "a"), ("slinky", "b"),
                     ("slinky", "c"), ("k8s", "k")]  # fmt: skip
    ]
    return {
        "startup": svg_chart("Submit to first training step",
                             "Median of warm runs; darker = submit → driver start, lighter = driver start → first "
                             "step; line = fastest to slowest.", startup),  # fmt: skip
        "recovery": svg_chart("Time to resume training after a failure",
                              "Median of 3 runs; line = fastest to slowest. Pass = the run resumed from its last "
                              "checkpoint and finished.", kill + preempt),  # fmt: skip
        "two-jobs": svg_chart("Two training jobs submitted onto the same nodes",
                              "Time until both jobs end (median of 3 runs), and what happened.", two),  # fmt: skip
    }


def readme_md() -> str:
    alts = {"startup": "Submit to first training step per scheduler",
            "recovery": "Time to resume training after a killed worker or a preemption",
            "two-jobs": "Two jobs on the same nodes: time until both end, and the outcome"}  # fmt: skip
    imgs = "\n\n".join(f"![{alt}](docs/results/{name}.svg)" for name, alt in alts.items())
    return (
        f"{imgs}\n\n_{HONESTY}_\n\nEvery metric with its min, max and run count: "
        f"[docs/results/table.md](docs/results/table.md). {host_line()}\n"
    )


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
    block = readme_md()
    svgs = charts(results)
    missing = missing_required(results)

    if a.check:
        ok = True
        if readme_block(a.check.read_text()) != block:
            print(f"FAIL {a.check} results block differs from the generated block (run make bench)")
            ok = False
        generated = {RESULTS / "table.md": md, **{RESULTS / f"{n}.svg": s for n, s in svgs.items()}}
        for path, text in generated.items():
            if not path.exists() or path.read_text() != text:
                print(f"FAIL {path.relative_to(ROOT)} differs from the data (run make bench)")
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
    (RESULTS / "table.md").write_text(md, newline="\n")
    for name, text in svgs.items():
        (RESULTS / f"{name}.svg").write_text(text, newline="\n")
    readme = a.readme.read_text()
    new = readme.split(START)[0] + START + "\n" + block + END + readme.split(END, 1)[1]
    a.readme.write_text(new, newline="\n")
    print(f"wrote {RESULTS / 'results.csv'} ({len(results)} rows), table.md, {len(svgs)} charts, {a.readme}")
    for m in missing:
        print(f"warning: no data: {m}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
