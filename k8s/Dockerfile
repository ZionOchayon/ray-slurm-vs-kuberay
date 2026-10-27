# Ray on K8s image: the pinned rayproject/ray CPU image plus the same hash-locked Python packages as
# slurm/Dockerfile (train/requirements.lock, FR-31), with train/ baked in at the path the Slurm side
# mounts it (/opt/rayslurm/train). All versions come from versions.env; the ARGs have no defaults on
# purpose (a missing pin fails the build).
ARG RAY_IMAGE
FROM ${RAY_IMAGE}

ARG RAY_VERSION
ARG TORCH_VERSION
ARG TORCHVISION_VERSION

# The lock alone first, so editing train.py does not reinstall the packages.
COPY train/requirements.lock /tmp/requirements.lock
RUN test -n "${RAY_VERSION}" && test -n "${TORCH_VERSION}" && test -n "${TORCHVISION_VERSION}" \
    && grep -q "^torch==${TORCH_VERSION}+cpu " /tmp/requirements.lock \
    && grep -q "^torchvision==${TORCHVISION_VERSION}+cpu " /tmp/requirements.lock \
    && grep -q "^ray==${RAY_VERSION} " /tmp/requirements.lock \
    && pip install --no-cache-dir --require-hashes -r /tmp/requirements.lock \
        --index-url https://download.pytorch.org/whl/cpu --extra-index-url https://pypi.org/simple

COPY train/ /opt/rayslurm/train/
