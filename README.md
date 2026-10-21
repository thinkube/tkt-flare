# tkt-flare

The Flare inference server behind the LLM Gateway. It is the `flare`
optional component of Thinkube.

[Flare](https://github.com/NVIDIA/flare-local-inference) is NVIDIA's local
inference server for Blackwell GPUs of compute capability 12.0 (RTX PRO 6000)
and 12.1 (DGX Spark). It serves prepared runtime packages: model weights,
compiled kernels and captured CUDA graphs, made ahead of time for one GPU type
and one tensor-parallel size. It does not serve Hugging Face checkpoints.

## What it does

The container runs `flare run` on port 8000 with Flare's own API:
OpenAI chat completions, completions and responses, Anthropic messages,
`/v1/models`, `/health` and `/metrics`.

- **The package comes from MLflow.** The entrypoint finds the latest MLflow
  version of `MODEL_ID` and serves the package under `/mlflow-models`.
- **The publisher is approved by the catalog.** A Flare package is signed.
  The model's catalog entry names the publisher and the SHA-256 of its key
  (`publisher`). The mirror checks that the repository's `publisher.json`
  lists that key, and keeps the file beside the package. The pod passes the
  file, the namespace and the fingerprint to Flare, so no one is asked at
  start.
- **Memory follows the gateway's plan.** `--memory-limit` is the share of the
  GPU memory the gateway planned for the model (`VLLM_GPU_MEMORY_UTILIZATION`).

## How it reaches a user

It is installed and removed from the Optional Components page in
thinkube-control. The install deploys it with no pods (`replicas: 0`,
`gateway_managed: true`); `spec.llm_backend` in `thinkube.yaml` declares it a
backend of the LLM Gateway, for GPUs of compute capability 12.0 and 12.1 only.
The gateway creates a pod on the chosen node when a model is loaded.

A model is served by Flare when its catalog entry has `"server_type":
["flare"]`, `"format": "flare"`, the hardware `revision` of its package
repository (`gb10` for DGX Spark, `gb202` for RTX PRO 6000) and its
`publisher`.

## Image

The container is built on the Flare image of Local Inference Lab
(`ghcr.io/local-inference-lab/flare`), mirrored into Harbor as
`library/flare` by the Thinkube installer from
`thinkube-metadata/mirror_images.json`. The image has no CUDA toolkit or
Python; Flare loads the node's `libcuda.so.1`.

## Licence

This template is MIT licensed. Flare and each model package have their own
licences; a model's catalog entry states its licence and the attribution
the licence requires.
