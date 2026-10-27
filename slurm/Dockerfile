# Slurm node image: upstream slurm-docker-cluster plus a Ray + PyTorch (CPU) venv.
# All versions come from versions.env; the ARGs have no defaults on purpose (a missing pin fails the build).
# Python packages come from the hash-locked train/requirements.lock (FR-31), checked against the ARGs.
ARG SLURM_BASE_IMAGE
FROM ${SLURM_BASE_IMAGE}

ARG RAY_VERSION
ARG TORCH_VERSION
ARG TORCHVISION_VERSION

COPY train/requirements.lock /tmp/requirements.lock
# Separate venv: the upstream entrypoint keeps using the system python3; the global PATH is unchanged.
RUN test -n "${RAY_VERSION}" && test -n "${TORCH_VERSION}" && test -n "${TORCHVISION_VERSION}" \
    && grep -q "^torch==${TORCH_VERSION}+cpu " /tmp/requirements.lock \
    && grep -q "^torchvision==${TORCHVISION_VERSION}+cpu " /tmp/requirements.lock \
    && grep -q "^ray==${RAY_VERSION} " /tmp/requirements.lock \
    && python3.12 -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir --require-hashes -r /tmp/requirements.lock \
        --index-url https://download.pytorch.org/whl/cpu --extra-index-url https://pypi.org/simple \
    && rm /tmp/requirements.lock
