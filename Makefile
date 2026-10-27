# The single interface of the lab. Targets and variables: docs/SPEC.md §9.1.
# Note: GNU make reports any failing recipe as exit 2; the scripts print their own exit code reason.
SHELL := /bin/bash

include versions.env
export

COMPOSE := docker compose -p slurm --env-file versions.env -f slurm/docker-compose.yml
MIN_MEM_GIB ?= 6
EPOCHS ?= 2
WORKERS ?= 2
DATA ?= synthetic
SAMPLES ?= 8192
TIMEOUT ?= 1200
K8S_TIMEOUT ?= 1200
LAUNCHER ?= symmetric
EXCLUSIVE ?= 0
MEM_PER_NODE ?= 2G
SCHED ?= slurm
REPS ?= 3
REPS_M1 ?= 5
REPS_M2 ?= 3
ifndef RUN
RUN := $(SCHED)-$(shell date -u +%Y%m%d-%H%M%S)
endif
# `make verify` without RUN= checks the latest run instead of a fresh timestamp.
VERIFY_RUN := $(if $(filter file,$(origin RUN)),$(shell cat .runs/latest 2>/dev/null),$(RUN))

.PHONY: up train-slurm train-k8s verify down drill-kill-worker drill-preempt drill-two-jobs bench

up:
	@COMPOSE="$(COMPOSE)" MIN_MEM_GIB="$(MIN_MEM_GIB)" bash scripts/up.sh

train-slurm:
	@RUN="$(RUN)" EPOCHS="$(EPOCHS)" WORKERS="$(WORKERS)" DATA="$(DATA)" SAMPLES="$(SAMPLES)" TIMEOUT="$(TIMEOUT)" \
		LAUNCHER="$(LAUNCHER)" EXCLUSIVE="$(EXCLUSIVE)" MEM_PER_NODE="$(MEM_PER_NODE)" bash scripts/train-slurm.sh

train-k8s:
	@RUN="$(RUN)" EPOCHS="$(EPOCHS)" WORKERS="$(WORKERS)" DATA="$(DATA)" SAMPLES="$(SAMPLES)" \
		K8S_TIMEOUT="$(K8S_TIMEOUT)" bash scripts/train-k8s.sh

verify:
	@run="$(VERIFY_RUN)"; \
	if [[ "$(SCHED)" == k8s ]]; then \
		if [[ -z "$$run" || ! -f ".runs/$$run.k8s" ]]; then \
			echo "verify: no K8s run found (pass RUN=<run>; .runs/<run>.k8s must exist)" >&2; exit 2; \
		fi; \
		docker run --rm -v "$$PWD/.data/k8s:/data" -v "$$PWD:/opt/rayslurm:ro" "rayk8s:$(RAY_VERSION)" \
			python /opt/rayslurm/scripts/verify.py --no-slurm --run "$$run" --job-state "$$(cat ".runs/$$run.k8s")"; \
	elif [[ "$(SCHED)" == slurm ]]; then \
		if [[ -z "$$run" || ! -f ".runs/$$run.jobid" ]]; then \
			echo "verify: no run found (pass RUN=<run>; .runs/<run>.jobid must exist)" >&2; exit 2; \
		fi; \
		docker exec slurmctld /opt/venv/bin/python /opt/rayslurm/scripts/verify.py \
			--run "$$run" --job-id "$$(cat ".runs/$$run.jobid")" \
			--launcher "$$(cat ".runs/$$run.launcher" 2>/dev/null || echo symmetric)"; \
	else \
		echo "verify: SCHED must be slurm or k8s" >&2; exit 2; \
	fi

drill-kill-worker drill-preempt drill-two-jobs:
	@SCHED="$(SCHED)" REPS="$(REPS)" bash drills/$(patsubst drill-%,%,$@).sh

bench:
	@REPS_M1="$(REPS_M1)" REPS_M2="$(REPS_M2)" REPS="$(REPS)" bash bench/bench.sh

down:
	$(COMPOSE) down -v --remove-orphans
	@if command -v kind >/dev/null && kind get clusters 2>/dev/null | grep -qx rayk8s; then \
		kind delete cluster --name rayk8s; fi
