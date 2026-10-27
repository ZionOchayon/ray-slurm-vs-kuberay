# Ray on K8s image: the pinned rayproject/ray CPU image plus the same torch CPU wheels and ray[train]
# as slurm/Dockerfile, with train/ baked in at the path the Slurm side mounts it (/opt/rayslurm/train).
# All versions come from versions.env; the ARGs have no defaults on purpose (a missing pin fails the build).
ARG RAY_IMAGE
FROM ${RAY_IMAGE}

ARG RAY_VERSION
ARG TORCH_VERSION
ARG TORCHVISION_VERSION

RUN test -n "${RAY_VERSION}" && test -n "${TORCH_VERSION}" && test -n "${TORCHVISION_VERSION}" \
    && pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu \
        "torch==${TORCH_VERSION}" "torchvision==${TORCHVISION_VERSION}" \
    && pip install --no-cache-dir "ray[train]==${RAY_VERSION}"

COPY train/ /opt/rayslurm/train/
