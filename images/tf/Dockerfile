# check=skip=InvalidDefaultArgInFrom
# TensorFlow dev pod: runpod/base (SSH, JupyterLab, /start.sh) + TensorFlow + Tailscale.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG TENSORFLOW_VERSION

# TensorFlow gets its own venv and Jupyter kernel: Ubuntu 24.04 marks the system
# Python as externally managed, and tensorflow[and-cuda] ships its own CUDA and
# cuDNN wheels, so the base needs only the host's NVIDIA driver, not a CUDA image.
RUN python3.12 -m venv /opt/tf && \
    /opt/tf/bin/pip install --no-cache-dir \
        "tensorflow[and-cuda]==${TENSORFLOW_VERSION}" ipykernel && \
    /opt/tf/bin/python -m ipykernel install --prefix=/usr/local \
        --name tf --display-name "TensorFlow ${TENSORFLOW_VERSION}"

COPY --from=tailscale /usr/local/bin/tailscale /usr/local/bin/tailscaled /usr/local/bin/
COPY --from=scripts --chmod=755 ts-entrypoint.sh /usr/local/bin/ts-entrypoint

ENTRYPOINT ["/usr/local/bin/ts-entrypoint"]
CMD ["/start.sh"]
