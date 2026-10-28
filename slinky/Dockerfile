# Slinky slurmd image: SchedMD's slurmd for Kubernetes plus the same Python 3.12 venv as slurm/Dockerfile
# (the base ships Python 3.14 only), installed from the hash-locked train/requirements.lock. train/,
# and the sbatch scripts are baked in at /opt/rayslurm, the path the Compose cluster mounts.
# All versions come from versions.env; the ARGs have no defaults on purpose (a missing pin fails the build).
ARG UV_IMAGE
ARG SLINKY_SLURMD_IMAGE
FROM ${UV_IMAGE} AS uv
FROM ${SLINKY_SLURMD_IMAGE}

ARG RAY_VERSION
ARG TORCH_VERSION
ARG TORCHVISION_VERSION
ARG SLINKY_PYTHON_VERSION

COPY --from=uv /uv /usr/local/bin/uv
COPY train/requirements.lock /tmp/requirements.lock
ENV UV_PYTHON_INSTALL_DIR=/opt/python
RUN test -n "${RAY_VERSION}" && test -n "${TORCH_VERSION}" && test -n "${TORCHVISION_VERSION}" \
    && test -n "${SLINKY_PYTHON_VERSION}" \
    && grep -q "^torch==${TORCH_VERSION}+cpu " /tmp/requirements.lock \
    && grep -q "^torchvision==${TORCHVISION_VERSION}+cpu " /tmp/requirements.lock \
    && grep -q "^ray==${RAY_VERSION} " /tmp/requirements.lock \
    && uv python install "${SLINKY_PYTHON_VERSION}" \
    && uv venv --python "${SLINKY_PYTHON_VERSION}" --seed /opt/venv \
    && uv pip install --python /opt/venv/bin/python --no-cache --require-hashes -r /tmp/requirements.lock \
        --index-url https://download.pytorch.org/whl/cpu --extra-index-url https://pypi.org/simple \
        --index-strategy unsafe-best-match \
    && rm /tmp/requirements.lock

COPY train/ /opt/rayslurm/train/
COPY slurm/sbatch/ /opt/rayslurm/slurm/sbatch/
