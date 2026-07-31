# AGENTS.md — llama.cpp / llama-swap / LiteLLM stack

Operational notes for working on this AI inference stack. These capture non-obvious gotchas
learned the hard way — read before editing any `llama-swap-*.yaml` or adding models.

## Architecture

Two machines, **three** llama-swap config files. Each llama-swap instance mounts exactly one
config and therefore advertises only models its device can actually run:

| config | instance | device | host port | models |
|---|---|---|---|---|
| `llama-swap-config.yaml` | `llama_swap_server` | 7900 XTX 24GB (desktop) | 8081 | `gemma-4-12b`, `gemma-4-26b`, `qwen3.6-27b`, `qwen3.6-35b`, `qwen3-coder-30b` |
| `llama-swap-nvidia.yaml` | `llama_swap_nvidia` | RTX 5070 8GB (laptop) | 8081 | `qwen3.5-9b` |
| `llama-swap-intel.yaml` | `llama_swap_intel` | Arc Pro iGPU (laptop) | 8082 | `gemma-4-e4b`, `gemma-4-e2b` |

**Ports follow device rank, not machine:** `8081` is always the primary GPU, `8082` the secondary
GPU, `8083` the NPU. The AMD desktop and the laptop's RTX both sit on 8081 because each is its
machine's primary GPU — they are separate hosts, so there is no conflict. A client pointed at
`:8081` gets the best GPU available wherever it is running.

**The laptop runs the nvidia and intel instances CONCURRENTLY** — `podman-compose -f
ai/llama-cpp.yml --profile laptop up -d`. They used to share `container_name: llama_swap_server`
and port 8081, which made them mutually exclusive; container name, ports and the config mount are
now set per-service instead of on the `base_llama_swap` anchor. Do not move them back into the
anchor.

### Which tier gets which work

Measured on the laptop with a 6524-token prompt:

| tier | model | prefill | decode |
|---|---|---|---|
| RTX 5070 | `qwen3.5-9b` | **1932 tok/s** (3.4s) | **48 tok/s** |
| Arc iGPU | `gemma-4-e4b` | 146 tok/s (44.7s) | 10 tok/s |
| Intel NPU | `Qwen3-1.7B` | 33 tok/s | **0.61 tok/s** |

The dGPU is ~13x faster at prefill and ~5x faster at decode, so **agent traffic belongs on the
dGPU** — agent prompts are prefill-dominated. The iGPU is not a "medium speed" tier in any
throughput sense; what it actually buys is a **second concurrent lane**. Each llama-swap instance
is `--parallel 1`, so delegation agents sharing one tier serialize; splitting them across devices
is the only way to get real concurrency on this laptop.

Semantic aliases in `litellm-config.yaml` are the interface agents should use — never hardcode a
checkpoint name:

| alias | model | tier | use |
|---|---|---|---|
| `local-reasoning` | `qwen3.5-9b` | RTX 5070 | main agent, coding, any large prompt |
| `local-fast` | `gemma-4-e4b` | Arc iGPU | parallel delegation lane, tool calling |
| `local-vision` | `gemma-4-e4b` | Arc iGPU | images/PDFs — the only vision tier |
| `local-tiny` | `gemma-4-e2b` | Arc iGPU | titles, classification, routing |

**The NPU is not in the serving path.** At 0.61 tok/s decode a 24-token tool call took 39s, versus
~7s warm on the iGPU. Tool calling *does* work there (correct arguments, `finish_reason:
tool_calls`) — the limit is throughput, not capability. The `intel_npu_llama_cpp` profile and the
container remain for experimentation; nothing in `litellm-config.yaml` routes to it. Reach it
directly on `localhost:8083` if you want to poke at it.

### Per-device notes

- **Intel iGPU (Arc)** — SYCL, via upstream-tracking `llama-swap:intel` image (`intel_llama_swap`
  profile).
  **Both iGPU models stay resident** via a llama-swap `groups` block with `swap: false`. Without
  it, alternating `local-fast` and `local-tiny` evicts and reloads a model every switch (~20s);
  with it, alternation costs ~0.4-0.8s. Combined weights are ~8GB against 62GB of system RAM.
  **Cold-start gotcha:** the `intel_sycl_cache` named volume (mounted at `/root/.cache`) persists
  the SYCL/Level-Zero JIT kernel cache across container restarts. Without it, every recreate
  recompiles all GPU kernels from scratch — measured 4m32s for the first request after a fresh
  volume vs. 18s once warm. If iGPU requests look "stuck"/timed-out right after `up`, that's this,
  not a broken deployment — wait it out once, or warm it manually before sending real traffic:
  `curl -s localhost:8082/v1/chat/completions -d '{"model":"gemma-4-e4b","messages":[{"role":"user","content":"hi"}],"max_tokens":8}'`.
  Client-side timeouts (LiteLLM, OpenAI SDKs) are often shorter than the cold-compile time, so the
  first real request can look like total failure (200 response, 0-byte body) even though the
  backend is fine — it just hadn't finished compiling yet.
- **Intel NPU (EXPERIMENTAL, not routed)** — `intel_npu_llama_cpp` profile,
  `intel_npu_llama_server` service. Standalone `llama-server` (no llama-swap integration exists for
  the OpenVINO backend yet), one fixed model (`Qwen3-1.7B-Q4_0.gguf`), host port 8083, `-c 1024`.
  Can run alongside either GPU tier since it uses a separate device (`/dev/accel`) — but note the
  iGPU and NPU share the same LPDDR5x bus as the CPU, so running both concurrently slows both.
  They are not independent throughput adders. See `ai/LLAMA-CPP.md` for the measurements.

Request flow: agents → LiteLLM (`:4000`) → the appropriate llama-swap instance (`:8081` primary
GPU / `:8082` iGPU on the host) → spawned `llama-server` subprocess per model. LiteLLM also routes to
cloud (Anthropic/Gemini).
Model GGUFs live in `${LLAMA_MODELS_DIR:-~/.llama/models}` (host), mounted to `/models` in the
container — export `LLAMA_MODELS_DIR` before `podman-compose up` to point at a different path
(e.g. this laptop uses `/mnt/data/llama/models`).

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
- 8GB dGPU tier (`llama-swap-nvidia.yaml`): `q4_0` KV cache — 8GB is a hard wall here.
  `qwen3.5-9b` at 64K + `--ubatch-size 512` measures 6303 MiB of 8151 MiB, ~1.8GB headroom.
  Fallback levers if it OOMs: `--ubatch-size` 512 → 384 → 256, *then* `--ctx-size` 64K → 32K.
- iGPU tier (`llama-swap-intel.yaml`): `q8_0` KV and much larger batches than the dGPU tier,
  because the Arc iGPU has **no dedicated VRAM** — it allocates from 62GB of system RAM, so the
  8GB-tier concessions buy nothing there. Measured ubatch sweep on a 6524-token prefill:
  128 → 104 tok/s, 512 → 126, **1024 → 146 (best)**, 2048 → 136 (overshoots, regresses).
  The ceiling is memory bandwidth, not batch size: a 8x ubatch increase bought only ~40%.
  Do not expect more from further tuning here.
- Per-model sampling baked in as defaults (Qwen: temp 0.7/top-k 20/top-p 0.95/min-p 0;
  Gemma: temp 1.0/top-k 64/top-p 0.95). Clients can override per request.
- Deliberately not used: `--mlock` (fights llama-swap's TTL load/unload), `--n-cpu-moe` (nothing
  needs CPU expert offload at current assignments — it's the lever for bigger models/longer ctx).

## Testing / verification

```bash
# direct to a llama-swap instance (bypasses LiteLLM) — fastest way to smoke-test a model loads
curl -s localhost:8081/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.5-9b","messages":[{"role":"user","content":"hi"}],"max_tokens":400}'    # dGPU
curl -s localhost:8082/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"gemma-4-e4b","messages":[{"role":"user","content":"hi"}],"max_tokens":400}'   # iGPU

# which models are loaded right now, per tier
curl -s localhost:8082/v1/models | jq '[.data[] | {id, status: .status.value}]'

podman logs --tail 20 llama_swap_intel      # or llama_swap_nvidia — "Health check passed"/crashes
nvidia-smi --query-gpu=memory.used,memory.total --format=csv   # dGPU VRAM after a model loads
free -h                                                        # iGPU "VRAM" is host RAM
```

Gemma/Qwen are **thinking models**: with a small `max_tokens` the answer can land entirely in
`reasoning_content` with empty `content` and `finish_reason: length`. That's not a failure —
raise `max_tokens`. This bites harder than it sounds: `qwen3.5-9b` asked to "reply with just OK"
spent 176 completion tokens reasoning before emitting `OK`, and returned **empty content** at
`max_tokens: 16`. Give local models generous budgets (400+) or agents will see blank replies.

**LiteLLM timeouts:** local inference is slow enough to trip LiteLLM's default request timeout —
a cold load plus a vision prefill measured 19.4s and surfaced as a useless
`InternalServerError - Connection error`. `request_timeout: 600` is set in `litellm-config.yaml`;
don't lower it.

**LiteLLM fallbacks are matched on the requested name, not the resolved one.** A request for the
alias `local-vision` does *not* inherit a fallback declared for `gemma-4-e4b` — it fails with
`No fallback model group found for original model_group=local-vision`. Every alias needs its own
entry in the `fallbacks` list; they are there, keep them in sync when adding aliases.
