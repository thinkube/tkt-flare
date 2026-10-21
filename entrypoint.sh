#!/bin/sh

# Copyright Alejandro Martínez Corriá and the Thinkube contributors
# SPDX-License-Identifier: MIT

# Serves the Flare runtime package of $MODEL_ID with Flare's own API on port
# 8000. The package was mirrored from Hugging Face into MLflow; its files are
# under /mlflow-models. Flare serves a copy of them on the node's local disk
# ($NODE_CACHE_DIR): it reads the embedding tables row by row while it
# serves, and each read through the Thinkube Storage mount is a round trip.
# The publisher's key comes from the package's publisher.json, mirrored beside
# it, and is approved by the fingerprint the model's catalog entry names.

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
require NODE_CACHE_DIR "the component's thinkube.yaml declares nodeCache"
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

# The node keeps one copy per model, in a folder named after its MLflow run;
# a copy of an older mirror of the model is removed first. A copy is complete
# once its folder has .complete; a copy cut short is started again.
local_dir="$NODE_CACHE_DIR/$run_id"
if [ ! -f "$local_dir/.complete" ]; then
    for old in "$NODE_CACHE_DIR"/*; do
        [ -d "$old" ] || continue
        [ "$old" = "$local_dir" ] && continue
        if [ -f "$old/.model" ] && [ "$(cat "$old/.model")" = "$MODEL_ID" ]; then
            echo "Removing the copy of an older mirror: $old"
            rm -rf "$old"
        fi
    done
    rm -rf "$local_dir"
    files=$(find "$model_dir" -maxdepth 1 -type f \( -name '*.safetensors' -o -name publisher.json \))
    need=$(echo "$files" | xargs -d '\n' stat -c %s | awk '{s += $1} END {print s}')
    free=$(df -B1 --output=avail "$NODE_CACHE_DIR" | tail -1 | tr -d ' ')
    if [ "$free" -lt "$need" ]; then
        echo "The node has $free bytes free in $NODE_CACHE_DIR; the package of $MODEL_ID needs $need" >&2
        exit 1
    fi
    mkdir -p "$local_dir"
    echo "$MODEL_ID" > "$local_dir/.model"
    echo "Copying $need bytes of $MODEL_ID to the node's disk ($local_dir)"
    start=$(date +%s)
    (
        while sleep 60; do
            echo "  copied $(du -sb "$local_dir" | cut -f1) of $need bytes"
        done
    ) &
    progress=$!
    echo "$files" | xargs -d '\n' cp -t "$local_dir"
    kill "$progress"
    touch "$local_dir/.complete"
    echo "Copied in $(( $(date +%s) - start ))s"
fi
packages="$local_dir/$(basename "$packages")"

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
    --publisher-keys "$local_dir/publisher.json" \
    --dangerously-accept-publisher "$PACKAGE_PUBLISHER" \
    --dangerously-approve-key "$PACKAGE_PUBLISHER_KEY" \
    --trust-store /tmp/flare/trust.toml \
    --gpus 0 \
    --host 0.0.0.0 \
    --port 8000 \
    --served-model-name "$MODEL_ID" \
    --memory-limit "$VLLM_GPU_MEMORY_UTILIZATION" \
    "$@"
