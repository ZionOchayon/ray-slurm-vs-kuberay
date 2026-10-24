"""One training job for both schedulers: Ray Train TorchTrainer on CPU, a checkpoint every epoch.

Uses Ray Train V2 (the default in Ray 2.59.0). v0.1 trains on seeded synthetic data only, so nothing is
downloaded; FashionMNIST arrives in v0.2. Multi-node runs need --storage-path on a shared filesystem.
Exit: 0 finished, 1 training failed, 2 invalid arguments.
"""

import argparse
import json
import os
import re
import tempfile
from pathlib import Path

os.environ.setdefault("RAY_TRAIN_V2_ENABLED", "1")

import ray
import ray.train
import ray.train.torch
import torch
from torch import nn
from torch.utils.data import DataLoader, TensorDataset

RUN_RE = re.compile(r"[a-z0-9]([a-z0-9-]{0,40}[a-z0-9])?")


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
    p.add_argument("--data", choices=["synthetic"], default="synthetic")
    p.add_argument("--synthetic-samples", type=int, default=8192)
    p.add_argument("--batch-size", type=int, default=128, help="per worker")
    p.add_argument("--seed", type=int, default=0)
    p.add_argument("--max-failures", type=int, default=3)
    a = p.parse_args(argv)
    if not RUN_RE.fullmatch(a.run_name):
        p.error(f"--run-name must match {RUN_RE.pattern}")
    if a.epochs < 1 or a.workers < 1 or a.batch_size < 1 or a.max_failures < 0:
        p.error(
            "--epochs, --workers and --batch-size must be >= 1; --max-failures >= 0"
        )
    if a.synthetic_samples < a.workers:
        p.error("--synthetic-samples must be >= --workers")
    return a


def make_model() -> nn.Module:
    # 28x28 -> conv3 26 -> pool 13 -> conv3 11 -> pool 5
    return nn.Sequential(
        nn.Conv2d(1, 16, 3), nn.ReLU(), nn.MaxPool2d(2),
        nn.Conv2d(16, 32, 3), nn.ReLU(), nn.MaxPool2d(2),
        nn.Flatten(), nn.Linear(32 * 5 * 5, 10),
    )  # fmt: skip


def train_loop(config: dict) -> None:
    ctx = ray.train.get_context()
    rank = ctx.get_world_rank()

    gen = torch.Generator().manual_seed(config["seed"])
    x = torch.randn(config["samples"], 1, 28, 28, generator=gen)
    y = torch.randint(0, 10, (config["samples"],), generator=gen)
    loader = ray.train.torch.prepare_data_loader(
        DataLoader(TensorDataset(x, y), batch_size=config["batch_size"], shuffle=True)
    )

    torch.manual_seed(config["seed"])
    model = ray.train.torch.prepare_model(make_model())
    opt = torch.optim.SGD(model.parameters(), lr=0.05, momentum=0.9)
    loss_fn = nn.CrossEntropyLoss()

    # Which Ray node each rank runs on; proves the 2 workers really sit on 2 nodes.
    ip = ray.util.get_node_ip_address()
    worker_node_ips = [ip]
    if torch.distributed.is_available() and torch.distributed.is_initialized():
        worker_node_ips = [None] * ctx.get_world_size()
        torch.distributed.all_gather_object(worker_node_ips, ip)

    step = 0
    for epoch in range(config["epochs"]):
        model.train()
        total, batches = 0.0, 0
        for xb, yb in loader:
            opt.zero_grad()
            loss = loss_fn(model(xb), yb)
            loss.backward()
            opt.step()
            total += loss.item()
            batches += 1
            step += 1

        metrics = {
            "epoch": epoch,
            "loss": total / max(batches, 1),
            "global_step": step,
            "worker_node_ips": worker_node_ips,
            "torch_num_threads": torch.get_num_threads(),
        }
        # report() is a barrier: every rank calls it each epoch; only rank 0 hands over a checkpoint.
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


def main(argv=None) -> None:
    a = parse_args(argv)
    trainer = ray.train.torch.TorchTrainer(
        train_loop,
        train_loop_config={
            "epochs": a.epochs,
            "samples": a.synthetic_samples,
            "batch_size": a.batch_size,
            "seed": a.seed,
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
        "scheduler": "slurm" if os.environ.get("SLURM_JOB_ID") else "local",
        "job_id": os.environ.get("SLURM_JOB_ID"),
        "epochs": a.epochs,
        "workers": a.workers,
        "data": a.data,
        "samples": a.synthetic_samples,
        "batch_size": a.batch_size,
        "seed": a.seed,
        "worker_node_ips": m.get("worker_node_ips"),
        "final_loss": m.get("loss"),
        "torch_num_threads": m.get("torch_num_threads"),
        "ray_version": ray.__version__,
        "torch_version": torch.__version__,
        "status": "finished",
    }
    out = Path(a.storage_path) / a.run_name / "run.json"
    out.write_text(json.dumps(run_json, indent=2) + "\n")
    print(f"run.json written: {out}")


if __name__ == "__main__":
    main()
