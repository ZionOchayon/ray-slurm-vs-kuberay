# The single interface of the lab. Targets and variables: docs/SPEC.md §9.1.
# Note: GNU make reports any failing recipe as exit 2; the scripts print their own exit code reason.
SHELL := /bin/bash

include versions.env
export

COMPOSE := docker compose -p slurm --env-file versions.env -f slurm/docker-compose.yml
MIN_MEM_GIB ?= 6

.PHONY: up down

up:
	@COMPOSE="$(COMPOSE)" MIN_MEM_GIB="$(MIN_MEM_GIB)" bash scripts/up.sh

down:
	$(COMPOSE) down -v --remove-orphans
