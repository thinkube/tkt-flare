# Copyright Alejandro Martínez Corriá and the Thinkube contributors
# SPDX-License-Identifier: MIT

# Flare, built by Local Inference Lab from github.com/NVIDIA/flare-local-inference
# at commit e7b8c01, mirrored into Harbor (thinkube-metadata/mirror_images.json).
ARG CONTAINER_REGISTRY
FROM ${CONTAINER_REGISTRY}/library/flare:e7b8c01

# The entrypoint finds the model's package in MLflow with curl and jq.
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl jq \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/serve-package
RUN chmod 0755 /usr/local/bin/serve-package

USER flare
EXPOSE 8000
ENTRYPOINT ["/usr/local/bin/serve-package"]
