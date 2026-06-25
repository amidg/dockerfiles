# AGENTS.md — llama.cpp / llama-swap / LiteLLM stack

Operational notes for working on this AI inference stack. These capture non-obvious gotchas
learned the hard way — read before editing `llama-swap-config.yaml` or adding models.

## Architecture

Two independent single-GPU deployments share **one** `llama-swap-config.yaml` (no multi-machine
networking). Each machine runs llama-swap and is only ever sent models that fit it:

- **24GB tier** — Radeon 7900 XTX, ROCm (`amd_llama_swap` profile, `llama-swap:rocm` image).
  Big models: `gemma-4-12b`, `gemma-4-26b`, `qwen3.6-27b`, `qwen3.6-35b`, `qwen3-coder-30b`.
- **8GB tier** — mobile RTX 5070, CUDA (`nvidia_llama_swap` profile, `llama-swap:cuda` image).
  Small models: `qwen3.5-9b`, `gemma-4-e4b`, `gemma-4-e2b`.

Request flow: agents → LiteLLM (`:4000`) → llama-swap (`:8080` in-container, `:8081` on host) →
spawned `llama-server` subprocess per model. LiteLLM also routes to cloud (Anthropic/Gemini).
Model GGUFs live in `~/.llama/models` (host), mounted to `/models` in the container.

## Vision / mmproj — the #1 gotcha

Each vision model needs the multimodal projector built for **its own embedding dim**. Projectors
are **not** interchangeable across model sizes. A mismatch makes `llama-server` abort on load:
`mismatch between text model (n_embd=X) and mmproj (n_embd=Y)`.

This fails **silently** until first use: llama-swap spawns the subprocess on demand, so a
misconfigured model looks fine until an agent actually requests it, then crashes with
`upstream command exited prematurely` / `connection refused`.

Gemma 4 embedding dims are all distinct → one projector per model, no sharing:

| model | n_embd | native ctx | projector file |
|---|---|---|---|
| gemma-4-12b | 3840 | 256K | `gemma-4-12b-mmproj-F16.gguf` |
| gemma-4-26b | 2816 | 256K | `gemma-4-26b-mmproj-F16.gguf` |
| gemma-4-e4b | 2560 | 128K | `gemma-4-e4b-mmproj-F16.gguf` |
| gemma-4-e2b | 1536 | 128K | `gemma-4-e2b-mmproj-F16.gguf` |

Qwen 3.6 27b and 35b likewise use their own per-model projectors.

**Adding a vision model:** read the GGUF `*.embedding_length` metadata, then fetch the projector
from *that exact model's* Unsloth `*-GGUF` repo (file is `mmproj-F16.gguf`), saved as
`~/.llama/models/<model>-mmproj-F16.gguf`. Never reuse another size's projector.

## Build-specific facts (image `llama-swap:rocm`, llama-server build 9776 / ac4105d68)

- `--jinja` is **enabled by default** — do not add it; chat templates + reasoning extraction work.
- `--flash-attn` needs an explicit value in this build: `--flash-attn on`.
- This build **supports Qwen 3.6** out of the box — the "must build from source for Qwen3.6 rope"
  advice from older guides does **not** apply here.
- Available and used: `--cache-reuse`, `--batch-size`/`--ubatch-size`, `--cache-type-k/v`,
  `--n-cpu-moe`, `--mlock`, `--reasoning`, per-model sampling flags.

## Context: metadata vs runtime

Clients (e.g. the hermes agent) read `*.context_length` from GGUF metadata and advertise the
model's **native training context** (e.g. Gemma 4 26b = 262144 / 256K), regardless of the runtime
`--ctx-size` cap. This is cosmetic; the actual KV-cache allocation is whatever `--ctx-size` sets.

## Tuning conventions in this config

- All models `--parallel 1` so `--ctx-size` is the full per-request window.
- 24GB tier: `q8_0` KV cache, `--ubatch-size` raised (2048 for the small-weight 12b, 1024 for the
  ~17GB models) for prefill throughput. Verify VRAM with `rocm-smi` after changing batch sizes;
  if a 17GB model OOMs, drop its `--ubatch-size` back to 512.
- 8GB tier: `q4_0` KV cache, conservative batch sizes to fit. `qwen3.5-9b` at 64K is the tight one
  (dense → no expert offload); fallback levers are lower `--ubatch-size`, then lower `--ctx-size`.
- Per-model sampling baked in as defaults (Qwen: temp 0.7/top-k 20/top-p 0.95/min-p 0;
  Gemma: temp 1.0/top-k 64/top-p 0.95). Clients can override per request.
- Deliberately not used: `--mlock` (fights llama-swap's TTL load/unload), `--n-cpu-moe` (nothing
  needs CPU expert offload at current assignments — it's the lever for bigger models/longer ctx).

## Testing / verification

```bash
# direct to llama-swap (bypasses LiteLLM) — fastest way to smoke-test a model loads
curl -s localhost:8081/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"<name>","messages":[{"role":"user","content":"hi"}],"max_tokens":8}'

podman logs --tail 20 llama_swap_server         # look for "Health check passed" or crash reasons
podman exec llama_swap_server rocm-smi --showmeminfo vram   # VRAM after a model loads
```

Gemma/Qwen are **thinking models**: with a small `max_tokens` the answer can land entirely in
`reasoning_content` with empty `content` and `finish_reason: length`. That's not a failure —
raise `max_tokens`.
