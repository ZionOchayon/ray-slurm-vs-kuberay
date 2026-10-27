"""One training job for both schedulers: Ray Train TorchTrainer on CPU, a checkpoint every epoch.

Uses Ray Train V2 (the default in Ray 2.59.0). Trains on seeded synthetic data (no network, no files)
or on FashionMNIST, which the driver downloads once before fit(). Resumes from the latest checkpoint
of the same RunConfig(storage_path, name) and appends JSON Lines events to <run>/events.jsonl
(schema: docs/SPEC.md §9.5). Multi-node runs need --storage-path on a shared filesystem.
Exit: 0 finished, 1 training failed, 2 invalid arguments.
"""

import argparse
import hashlib
import json
import os
import re
import tempfile
import time
from pathlib import Path

os.environ.setdefault("RAY_TRAIN_V2_ENABLED", "1")

import ray
import ray.train
import ray.train.torch
import torch
from torch import nn
from torch.utils.data import DataLoader, TensorDataset

RUN_RE = re.compile(r"[a-z0-9]([a-z0-9-]{0,40}[a-z0-9])?")
SYNTHETIC_VAL_SAMPLES = 1024


def parse_args(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "--run-name",
        required=True,
        help="RunConfig.name; also the directory under --storage-path",
    )
    p.add_argument("--storage-path", default="/data/ray_results")
    p.add_argument("--epochs", type=int, default=2)
    p.add_argument("--workers", type=int, default=2)
    p.add_argument("--data", choices=["synthetic", "fashion-mnist"], default="synthetic")
    p.add_argument("--synthetic-samples", type=int, default=8192)
    p.add_argument("--batch-size", type=int, default=128, help="per worker")
    p.add_argument("--seed", type=int, default=0)
    p.add_argument("--max-failures", type=int, default=3)
    p.add_argument("--dataset-dir", default="/data/datasets", help="FashionMNIST root")
    p.add_argument("--progress-every", type=int, default=10, help="steps between progress events")
    a = p.parse_args(argv)
    if not RUN_RE.fullmatch(a.run_name):
        p.error(f"--run-name must match {RUN_RE.pattern}")
    if min(a.epochs, a.workers, a.batch_size, a.progress_every) < 1 or a.max_failures < 0:
        p.error(
            "--epochs, --workers, --batch-size and --progress-every must be >= 1; --max-failures >= 0"
        )
    if a.synthetic_samples < a.workers:
        p.error("--synthetic-samples must be >= --workers")
    return a


def detect_scheduler() -> tuple[str, str | None]:
    if os.environ.get("SLURM_JOB_ID"):
        return "slurm", os.environ["SLURM_JOB_ID"]
    if os.environ.get("KUBERNETES_SERVICE_HOST"):
        # Set in k8s/rayjob.yaml from the RayJob name; the pod name is the fallback.
        return "k8s", os.environ.get("RAYJOB_NAME") or os.environ.get("HOSTNAME")
    return "local", None


def emit(path: str, event: str, restart_count: int, epoch=None, global_step=None,
         epoch_train_s=None, ckpt_s=None) -> None:
    """Append one event to events.jsonl (schema in SPEC §9.5). One write() per line keeps lines whole."""
    rec = {
        "ts": time.time(), "event": event, "epoch": epoch, "global_step": global_step,
        "restart_count": restart_count, "epoch_train_s": epoch_train_s, "ckpt_s": ckpt_s,
    }  # fmt: skip
    with open(path, "a") as f:
        f.write(json.dumps(rec) + "\n")


def interrupted_attempts(events_path: Path) -> int:
    """Earlier driver attempts of this run that never wrote run_end (crashed, killed or preempted)."""
    count, open_attempt = 0, False
    try:
        lines = events_path.read_text().splitlines()
    except FileNotFoundError:
        return 0
    for line in lines:
        try:
            ev = json.loads(line).get("event")
        except ValueError:
            continue
        if ev == "driver_start":
            count += open_attempt
            open_attempt = True
        elif ev == "run_end":
            open_attempt = False
    return count + open_attempt


def make_model() -> nn.Module:
    # 28x28 -> conv3 26 -> pool 13 -> conv3 11 -> pool 5
    return nn.Sequential(
        nn.Conv2d(1, 16, 3), nn.ReLU(), nn.MaxPool2d(2),
        nn.Conv2d(16, 32, 3), nn.ReLU(), nn.MaxPool2d(2),
        nn.Flatten(), nn.Linear(32 * 5 * 5, 10),
    )  # fmt: skip


def fashion_mnist(root: str, train: bool, download: bool):
    from torchvision import datasets, transforms

    tf = transforms.Compose([transforms.ToTensor(), transforms.Normalize((0.2860,), (0.3530,))])
    return datasets.FashionMNIST(root, train=train, download=download, transform=tf)


def make_datasets(config: dict):
    if config["data"] == "fashion-mnist":
        # The driver downloaded the files already; workers only read them.
        root = config["dataset_dir"]
        return fashion_mnist(root, True, False), fashion_mnist(root, False, False)
    gen = torch.Generator().manual_seed(config["seed"])
    n = config["samples"]
    x = torch.randn(n + SYNTHETIC_VAL_SAMPLES, 1, 28, 28, generator=gen)
    y = torch.randint(0, 10, (n + SYNTHETIC_VAL_SAMPLES,), generator=gen)
    return TensorDataset(x[:n], y[:n]), TensorDataset(x[n:], y[n:])


def evaluate(model: nn.Module, loader) -> float:
    """Accuracy over the whole validation set, summed across ranks."""
    model.eval()
    correct = torch.zeros(2)
    with torch.no_grad():
        for xb, yb in loader:
            correct[0] += (model(xb).argmax(1) == yb).sum()
            correct[1] += len(yb)
    if torch.distributed.is_available() and torch.distributed.is_initialized():
        torch.distributed.all_reduce(correct)
    return (correct[0] / correct[1].clamp(min=1)).item()


def train_loop(config: dict) -> None:
    ctx = ray.train.get_context()
    rank = ctx.get_world_rank()
    restarts = config["restart_count"]
    events = config["events_path"]

    def log_event(event: str, **kw) -> None:
        if rank == 0:
            emit(events, event, restarts, **kw)

    log_event("loop_start")

    train_ds, val_ds = make_datasets(config)
    loader = ray.train.torch.prepare_data_loader(
        DataLoader(train_ds, batch_size=config["batch_size"], shuffle=True)
    )
    val_loader = ray.train.torch.prepare_data_loader(
        DataLoader(val_ds, batch_size=512, shuffle=False)
    )

    torch.manual_seed(config["seed"])
    model = make_model()
    opt_state, start_epoch, step = None, 0, 0
    checkpoint = ray.train.get_checkpoint()
    if checkpoint:
        with checkpoint.as_directory() as d:
            state = torch.load(Path(d) / "model.pt", weights_only=True)
        model.load_state_dict(state["model"])
        opt_state, start_epoch, step = state["optimizer"], state["epoch"] + 1, state["global_step"]
        if rank == 0:
            print(f"restored epoch={state['epoch']} global_step={step}", flush=True)
        log_event("restored", epoch=state["epoch"], global_step=step)

    model = ray.train.torch.prepare_model(model)
    opt = torch.optim.SGD(model.parameters(), lr=0.05, momentum=0.9)
    if opt_state:
        opt.load_state_dict(opt_state)
    loss_fn = nn.CrossEntropyLoss()

    # Which Ray node each rank runs on; proves the 2 workers really sit on 2 nodes.
    ip = ray.util.get_node_ip_address()
    worker_node_ips = [ip]
    if torch.distributed.is_available() and torch.distributed.is_initialized():
        worker_node_ips = [None] * ctx.get_world_size()
        torch.distributed.all_gather_object(worker_node_ips, ip)

    first_step_done = False
    for epoch in range(start_epoch, config["epochs"]):
        if ctx.get_world_size() > 1:
            loader.sampler.set_epoch(epoch)
        model.train()
        total, batches = 0.0, 0
        t0 = time.perf_counter()
        for xb, yb in loader:
            opt.zero_grad()
            loss = loss_fn(model(xb), yb)
            loss.backward()
            opt.step()
            total += loss.item()
            batches += 1
            step += 1
            if not first_step_done:
                first_step_done = True
                log_event("first_step", epoch=epoch, global_step=step)
            if step % config["progress_every"] == 0:
                log_event("progress", epoch=epoch, global_step=step)
        epoch_train_s = time.perf_counter() - t0
        val_accuracy = evaluate(model, val_loader)

        metrics = {
            "epoch": epoch,
            "loss": total / max(batches, 1),
            "val_accuracy": val_accuracy,
            "global_step": step,
            "worker_node_ips": worker_node_ips,
            "torch_num_threads": torch.get_num_threads(),
        }
        # report() is a barrier: every rank calls it each epoch; only rank 0 hands over a checkpoint.
        t1 = time.perf_counter()
        with tempfile.TemporaryDirectory() as tmp:
            checkpoint = None
            if rank == 0:
                state = {
                    "model": getattr(model, "module", model).state_dict(),
                    "optimizer": opt.state_dict(),
                    "epoch": epoch,
                    "global_step": step,
                }
                torch.save(state, Path(tmp) / "model.pt")
                checkpoint = ray.train.Checkpoint.from_directory(tmp)
            ray.train.report(
                metrics,
                checkpoint=checkpoint,
                checkpoint_dir_name=f"checkpoint_epoch_{epoch:03d}",
            )
        log_event("epoch_end", epoch=epoch, global_step=step, epoch_train_s=epoch_train_s,
                  ckpt_s=time.perf_counter() - t1)


def file_sha256(path: str) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main(argv=None) -> None:
    a = parse_args(argv)
    scheduler, job_id = detect_scheduler()
    run_dir = Path(a.storage_path) / a.run_name
    run_dir.mkdir(parents=True, exist_ok=True)
    events = run_dir / "events.jsonl"
    # Slurm counts requeues itself; elsewhere a restart is an earlier attempt that never finished.
    if scheduler == "slurm":
        restarts = int(os.environ.get("SLURM_RESTART_COUNT", "0"))
    else:
        restarts = interrupted_attempts(events)
    emit(str(events), "driver_start", restarts)
    print(f"driver_start run={a.run_name} scheduler={scheduler} restart_count={restarts}", flush=True)

    if a.data == "fashion-mnist":
        # Download once on the driver, into shared storage, before any worker starts.
        fashion_mnist(a.dataset_dir, True, True)
        fashion_mnist(a.dataset_dir, False, True)

    trainer = ray.train.torch.TorchTrainer(
        train_loop,
        train_loop_config={
            "epochs": a.epochs,
            "data": a.data,
            "dataset_dir": a.dataset_dir,
            "samples": a.synthetic_samples,
            "batch_size": a.batch_size,
            "seed": a.seed,
            "progress_every": a.progress_every,
            "restart_count": restarts,
            "events_path": str(events),
        },
        scaling_config=ray.train.ScalingConfig(
            num_workers=a.workers, use_gpu=False, placement_strategy="SPREAD"
        ),
        run_config=ray.train.RunConfig(
            name=a.run_name,
            storage_path=a.storage_path,
            checkpoint_config=ray.train.CheckpointConfig(num_to_keep=None),
            failure_config=ray.train.FailureConfig(max_failures=a.max_failures),
        ),
    )
    result = trainer.fit()  # raises on failure, so the process exits non-zero

    m = result.metrics or {}
    run_json = {
        "run": a.run_name,
        "scheduler": scheduler,
        "job_id": job_id,
        "epochs": a.epochs,
        "workers": a.workers,
        "data": a.data,
        "samples": a.synthetic_samples if a.data == "synthetic" else None,
        "batch_size": a.batch_size,
        "seed": a.seed,
        "worker_node_ips": m.get("worker_node_ips"),
        "final_loss": m.get("loss"),
        "val_accuracy": m.get("val_accuracy"),
        "torch_num_threads": m.get("torch_num_threads"),
        "ray_version": ray.__version__,
        "torch_version": torch.__version__,
        "train_py_sha256": file_sha256(__file__),
        "status": "finished",
        "restart_count": restarts,
    }
    out = run_dir / "run.json"
    out.write_text(json.dumps(run_json, indent=2) + "\n")
    emit(str(events), "run_end", restarts, epoch=m.get("epoch"), global_step=m.get("global_step"))
    print(f"run.json written: {out}")


if __name__ == "__main__":
    main()
