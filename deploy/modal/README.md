# Muse Glimmer on Modal

A private, OpenAI-compatible endpoint serving Muse Glimmer 30B for Doc's `summary` role.

**Status (2026-10-27): not yet deployed.** The Modal CLI is set up on Mike's Mac (logged in to
your Modal workspace), the `muse-glimmer-api-key` secret and the two Volumes exist, and
`MODAL_GLIMMER_KEY` is in `~/.zshrc`. Modal refused to run the app: "Please add a payment
method to use L40S GPU functions." Modal requires a card on file for any GPU, even when credit
covers the cost. Until a card is added, Doc's `summary` role falls back to Baseten (Muse Spark
Open), and every fallback is logged.

## What it serves, and why

| | Choice | Source |
|---|---|---|
| Weights | `meta-models/Muse-Glimmer-30B`, revision `cec94fc…` (Meta's official repository, Apache 2.0, 29.8B BF16 parameters, about 60 GB) | Hugging Face model card |
| Server | vLLM 0.28.0 (`vllm/vllm-openai:v0.28.0`) with `--reasoning-parser muse_glimmer` and `--tool-call-parser muse_glimmer` | The official vLLM recipe (recipes.vllm.ai/meta-models/Muse-Glimmer-30B) gives 0.28.0 as the minimum version and these parsers as required |
| GPU | One L40S (48 GB), $1.95/hr on Modal | BF16 needs about 64 GB of VRAM (model card), so the weights must be quantized to fit |
| Quantization | `--quantization fp8`: vLLM quantizes the official BF16 weights to FP8 as it loads them; the L40S has native FP8 | The recipe's ready-made FP8 checkpoint is a third-party re-upload (RedHatAI), which this deployment does not use |
| Context | `--max-model-len 32768`, FP8 KV cache | Leaves KV-cache room on 48 GB; Doc's prompts are small |
| Inputs | Text only (`--limit-mm-per-prompt '{"image": 0, "video": 0}'`) | Doc sends no images |
| Sampling | `--generation-config auto` (temperature 1.0, top_p 0.95, top_k 64); Doc sends the same | Model card "Best practices" |
| Reasoning | Doc adds `Reasoning strength: low.` to the system prompt; the reasoning parser keeps the reasoning out of `content`, and Doc strips any that slips through | Model card: levels low / medium / high / xhigh, set in the system prompt |

**Untested risk:** vLLM's on-the-fly FP8 may need the full BF16 weights in GPU memory before it
quantizes them, which would not fit in 48 GB. If the first start fails with out-of-memory,
deploy on one A100-80GB and serve BF16 unquantized ($2.50/hr):

```sh
GLIMMER_GPU=A100-80GB GLIMMER_QUANTIZATION=none modal deploy deploy/modal/glimmer.py
```

llama.cpp with a GGUF was the other option the brief allowed. It is not used, because Meta's
repository has no GGUF; the GGUFs on Hugging Face are community re-uploads.

## Cost and scaling

- One container at most (`max_containers=1`), and none when idle (`min_containers=0`). It scales
  to zero after 5 idle minutes (`scaledown_window=300`).
- While awake: L40S $1.95/hr, plus 8 CPU cores (about $0.38/hr) and 64 GiB of memory (about
  $0.51/hr) at Modal's per-second rates: about **$2.85/hr**, or about $0.24 for one cold start
  followed by 5 idle minutes. Nothing is charged at zero containers.
- Doc cannot see GPU-seconds. `doc usage` lists Modal calls and tokens and says "billed by GPU
  time on Modal; check the Modal dashboard".

## Deploy

```sh
# Once: the bearer key (generated on the Mac, never printed or committed).
modal secret create muse-glimmer-api-key VLLM_API_KEY="$MODAL_GLIMMER_KEY"

# Once: copy the official weights into the muse-glimmer-hf-cache Volume (CPU only).
modal run deploy/modal/glimmer.py::download

# The endpoint. Modal prints its URL: https://<workspace>--muse-glimmer-serve.modal.run
modal deploy deploy/modal/glimmer.py
```

Give Doc the URL with `/v1` appended, either in `~/.config/dmc-doc/config.json`
(`{"providers": {"modal": {"baseUrl": "https://…modal.run/v1"}}}`) or with
`export DOC_MODAL_BASE_URL=…`. Do not commit the URL. Every request needs
`Authorization: Bearer $MODAL_GLIMMER_KEY`: vLLM reads the key from `VLLM_API_KEY`, set by the
secret, and serves `/v1/chat/completions` and `/v1/models` only to callers who send it.

Check it with `doc models --check` (the first call after idle wakes the GPU; Doc prints "Waking
Muse Glimmer on Modal (can take a couple of minutes)…" after 10 s and waits up to 600 s).
