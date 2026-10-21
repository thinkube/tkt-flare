#!/bin/sh

# Copyright Alejandro Martínez Corriá and the Thinkube contributors
# SPDX-License-Identifier: MIT

# Serves the Flare runtime package of $MODEL_ID with Flare's own API on port
# 8000. The package was mirrored from Hugging Face into MLflow; its files are
# under /mlflow-models. The publisher's key comes from the package's
# publisher.json, mirrored beside it, and is approved by the fingerprint the
# model's catalog entry names.

set -eu

MLFLOW_URL="http://mlflow.mlflow.svc.cluster.local:5000"

require() {
    eval "value=\${$1:-}"
    if [ -z "$value" ]; then
        echo "$1 is not set: $2" >&2
        exit 1
    fi
}

require MODEL_ID "the LLM gateway sets it when it creates the pod"
require PACKAGE_PUBLISHER "the model's catalog entry names its publisher (publisher.namespace)"
require PACKAGE_PUBLISHER_KEY "the model's catalog entry names its publisher's key (publisher.key_sha256)"
require VLLM_GPU_MEMORY_UTILIZATION "the LLM gateway sets it from the model's memory plan"
for name in MLFLOW_KEYCLOAK_TOKEN_URL MLFLOW_KEYCLOAK_CLIENT_ID MLFLOW_CLIENT_SECRET \
            MLFLOW_AUTH_USERNAME MLFLOW_AUTH_PASSWORD; do
    require "$name" "the component's MLflow credentials Secret provides it"
done

echo "Finding the package of $MODEL_ID in MLflow"
token=$(curl -sf -X POST "$MLFLOW_KEYCLOAK_TOKEN_URL" \
    --data-urlencode grant_type=password \
    --data-urlencode "client_id=$MLFLOW_KEYCLOAK_CLIENT_ID" \
    --data-urlencode "client_secret=$MLFLOW_CLIENT_SECRET" \
    --data-urlencode "username=$MLFLOW_AUTH_USERNAME" \
    --data-urlencode "password=$MLFLOW_AUTH_PASSWORD" \
    --data-urlencode scope=openid | jq -r '.access_token // empty') || true
if [ -z "$token" ]; then
    echo "Keycloak at $MLFLOW_KEYCLOAK_TOKEN_URL gave no MLflow token for $MLFLOW_AUTH_USERNAME" >&2
    exit 1
fi

registered=$(echo "$MODEL_ID" | tr / -)
run_id=$(curl -sf -G "$MLFLOW_URL/api/2.0/mlflow/model-versions/search" \
    -H "Authorization: Bearer $token" \
    --data-urlencode "filter=name='$registered'" \
    | jq -r '.model_versions // [] | max_by(.version | tonumber) | .run_id // empty')
if [ -z "$run_id" ]; then
    echo "$MODEL_ID is not registered in MLflow as $registered; mirror it first" >&2
    exit 1
fi
experiment_id=$(curl -sf -G "$MLFLOW_URL/api/2.0/mlflow/runs/get" \
    -H "Authorization: Bearer $token" \
    --data-urlencode "run_id=$run_id" | jq -r .run.info.experiment_id)

model_dir="/mlflow-models/artifacts/$experiment_id/$run_id/artifacts/model"

# The primary file of a package; its payload blobs are named by their SHA-256,
# and numbered companions end in -data-NN-of-NN.
packages=$(find "$model_dir" -maxdepth 1 -name '*.safetensors' \
    | grep -Ev '/[0-9a-f]{64}\.safetensors$|-data-[0-9]+-of-[0-9]+\.safetensors$' || true)
count=$(printf '%s' "$packages" | grep -c . || true)
if [ "$count" -ne 1 ]; then
    echo "Expected one Flare package in $model_dir, found $count: $packages" >&2
    exit 1
fi
if [ ! -f "$model_dir/publisher.json" ]; then
    echo "$model_dir has no publisher.json; mirror the model again" >&2
    exit 1
fi

# Arguments the model's catalog entry adds (server_args), as a JSON list.
if [ -n "${SERVER_ARGS:-}" ]; then
    if ! echo "$SERVER_ARGS" | jq -e 'type == "array" and all(type == "string")' >/dev/null; then
        echo "SERVER_ARGS is not a JSON list of strings: $SERVER_ARGS" >&2
        exit 1
    fi
fi
set --
while IFS= read -r arg; do
    if [ -n "$arg" ]; then set -- "$@" "$arg"; fi
done <<EOF_ARGS
$(echo "${SERVER_ARGS:-[]}" | jq -r '.[]')
EOF_ARGS

echo "Serving $packages"
# Flare records the approved publisher here; the approval is given again at
# every start by the flags below.
mkdir -p /tmp/flare
exec flare run "$packages" \
    --publisher-keys "$model_dir/publisher.json" \
    --dangerously-accept-publisher "$PACKAGE_PUBLISHER" \
    --dangerously-approve-key "$PACKAGE_PUBLISHER_KEY" \
    --trust-store /tmp/flare/trust.toml \
    --gpus 0 \
    --host 0.0.0.0 \
    --port 8000 \
    --served-model-name "$MODEL_ID" \
    --memory-limit "$VLLM_GPU_MEMORY_UTILIZATION" \
    "$@"
