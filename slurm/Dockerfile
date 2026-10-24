# Slurm node image: upstream slurm-docker-cluster plus a Ray + PyTorch (CPU) venv.
# All versions come from versions.env; the ARGs have no defaults on purpose (a missing pin fails the build).
ARG SLURM_BASE_IMAGE
FROM ${SLURM_BASE_IMAGE}

ARG RAY_VERSION
ARG TORCH_VERSION
ARG TORCHVISION_VERSION

# Separate venv: the upstream entrypoint keeps using the system python3; the global PATH is unchanged.
RUN test -n "${RAY_VERSION}" && test -n "${TORCH_VERSION}" && test -n "${TORCHVISION_VERSION}" \
    && python3.12 -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu \
        "torch==${TORCH_VERSION}" "torchvision==${TORCHVISION_VERSION}" \
    && /opt/venv/bin/pip install --no-cache-dir "ray[train]==${RAY_VERSION}"
