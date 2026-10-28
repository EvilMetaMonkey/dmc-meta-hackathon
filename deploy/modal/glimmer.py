"""Muse Glimmer 30B on Modal: a private, OpenAI-compatible endpoint for Doc.

Serves Meta's official weights (meta-models/Muse-Glimmer-30B, Apache 2.0)
with vLLM, following the official vLLM recipe for Muse Glimmer
(recipes.vllm.ai/meta-models/Muse-Glimmer-30B): vLLM >= 0.28.0 with the
muse_glimmer reasoning and tool-call parsers.

    modal run deploy/modal/glimmer.py::download   # once: weights -> Volume
    modal deploy deploy/modal/glimmer.py          # the endpoint

Every request needs `Authorization: Bearer <key>`. vLLM reads the key from
VLLM_API_KEY, which comes from the Modal Secret `muse-glimmer-api-key`. The
key and the endpoint URL are never committed.
"""

import os
import subprocess

import modal

MODEL = "meta-models/Muse-Glimmer-30B"
# Pinned revision of Meta's official repository (2026-10-22).
REVISION = "cec94fcfd6512f2cfe708138c32533b346ea4f69"
SERVED_NAME = "muse-glimmer"
VLLM_IMAGE = "vllm/vllm-openai:v0.28.0"
PORT = 8000

# One L40S (48 GB). The BF16 weights (~60 GB) do not fit, so vLLM quantizes
# them to FP8 when loading; the L40S has native FP8. GLIMMER_GPU can switch
# to "A100-80GB" to serve BF16 unquantized (set GLIMMER_QUANTIZATION=none).
GPU = os.environ.get("GLIMMER_GPU", "L40S")
QUANTIZATION = os.environ.get("GLIMMER_QUANTIZATION", "fp8")
MAX_MODEL_LEN = os.environ.get("GLIMMER_MAX_MODEL_LEN", "32768")

hf_cache = modal.Volume.from_name("muse-glimmer-hf-cache", create_if_missing=True)
vllm_cache = modal.Volume.from_name("muse-glimmer-vllm-cache", create_if_missing=True)
VOLUMES = {"/root/.cache/huggingface": hf_cache, "/root/.cache/vllm": vllm_cache}

image = (
    # The vLLM image ships python3 but no `python`, which Modal needs.
    modal.Image.from_registry(
        VLLM_IMAGE,
        setup_dockerfile_commands=[
            "RUN ln -sf $(command -v python3) /usr/local/bin/python"
        ],
    )
    .entrypoint([])
    .env({"HF_XET_HIGH_PERFORMANCE": "1", "VLLM_NO_USAGE_STATS": "1"})
)

app = modal.App("muse-glimmer", image=image)


@app.function(volumes=VOLUMES, timeout=60 * 60, cpu=4, memory=8192)
def download() -> str:
    """Fetch the official weights into the Volume, so cold starts never
    re-download them."""
    from huggingface_hub import snapshot_download

    path = snapshot_download(MODEL, revision=REVISION)
    hf_cache.commit()
    total = sum(
        os.path.getsize(os.path.join(root, name))
        for root, _, names in os.walk(path)
        for name in names
    )
    return f"{MODEL}@{REVISION[:12]}: {total / 1e9:.1f} GB in {path}"


@app.function(
    gpu=GPU,
    volumes=VOLUMES,
    secrets=[modal.Secret.from_name("muse-glimmer-api-key")],
    # Scale to zero after 5 idle minutes; never more than one GPU.
    scaledown_window=5 * 60,
    min_containers=0,
    max_containers=1,
    timeout=24 * 60 * 60,
    cpu=8,
    memory=65536,
)
@modal.concurrent(max_inputs=16)
@modal.web_server(port=PORT, startup_timeout=20 * 60)
def serve():
    if not os.environ.get("VLLM_API_KEY"):
        raise RuntimeError("The muse-glimmer-api-key secret must set VLLM_API_KEY.")
    command = [
        "vllm",
        "serve",
        MODEL,
        "--revision",
        REVISION,
        "--served-model-name",
        SERVED_NAME,
        "--host",
        "0.0.0.0",
        "--port",
        str(PORT),
        "--max-model-len",
        MAX_MODEL_LEN,
        "--max-num-seqs",
        "16",
        "--gpu-memory-utilization",
        "0.92",
        "--kv-cache-dtype",
        "fp8",
        "--reasoning-parser",
        "muse_glimmer",
        "--tool-call-parser",
        "muse_glimmer",
        "--enable-auto-tool-choice",
        "--generation-config",
        "auto",
        # Doc sends text only; skipping image inputs saves encoder memory.
        "--limit-mm-per-prompt",
        '{"image": 0, "video": 0}',
    ]
    if QUANTIZATION != "none":
        command += ["--quantization", QUANTIZATION]
    # Weights come from the Volume; never re-download at start-up.
    env = {**os.environ, "HF_HUB_OFFLINE": "1"}
    subprocess.Popen(command, env=env)
