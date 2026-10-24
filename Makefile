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
ifndef RUN
RUN := slurm-$(shell date -u +%Y%m%d-%H%M%S)
endif
# `make verify` without RUN= checks the latest run instead of a fresh timestamp.
VERIFY_RUN := $(if $(filter file,$(origin RUN)),$(shell cat .runs/latest 2>/dev/null),$(RUN))

.PHONY: up train-slurm verify down

up:
	@COMPOSE="$(COMPOSE)" MIN_MEM_GIB="$(MIN_MEM_GIB)" bash scripts/up.sh

train-slurm:
	@RUN="$(RUN)" EPOCHS="$(EPOCHS)" WORKERS="$(WORKERS)" DATA="$(DATA)" SAMPLES="$(SAMPLES)" TIMEOUT="$(TIMEOUT)" \
		bash scripts/train-slurm.sh

verify:
	@run="$(VERIFY_RUN)"; \
	if [[ -z "$$run" || ! -f ".runs/$$run.jobid" ]]; then \
		echo "verify: no run found (pass RUN=<run>; .runs/<run>.jobid must exist)" >&2; exit 2; \
	fi; \
	docker exec slurmctld /opt/venv/bin/python /opt/rayslurm/scripts/verify.py \
		--run "$$run" --job-id "$$(cat ".runs/$$run.jobid")"

down:
	$(COMPOSE) down -v --remove-orphans
