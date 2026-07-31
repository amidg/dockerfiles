# AGENTS.md — llama.cpp / llama-swap / LiteLLM stack

Operational notes for working on this AI inference stack. These capture non-obvious gotchas
learned the hard way — read before editing any `llama-swap-*.yaml`, either `litellm-config.*.yaml`,
or adding models.

## Architecture

Two machines. Each llama-swap instance mounts exactly one config and therefore advertises only
models its device can actually run:

| config | instance | device | host port | models |
|---|---|---|---|---|
| `llama-swap-config.yaml` | `llama_swap_server` | 7900 XTX 24GB (desktop) | 8081 | `gemma-4-12b`, `gemma-4-26b`, `qwen3.6-27b`, `qwen3.6-35b`, `qwen3-coder-30b` (+ an unused 8GB-tier section kept so the file works standalone) |
| `llama-swap-nvidia.yaml` | `llama_swap_nvidia` | RTX 5070 8GB (laptop) | 8081 | `gemma-4-26b` (default), `qwen3.5-9b` |
| `llama-swap-intel.yaml` | `llama_swap_intel` | Arc Pro iGPU (laptop) | 8082 | `gemma-4-e2b` (text-only, non-thinking), `embed` |

LiteLLM is likewise per-machine — `litellm-config.laptop.yaml` and `litellm-config.desktop.yaml`,
selected by the compose profile (`laptop` vs `amd_llama_cpp`), so there is no env var to forget.
Both files define the **same alias names**; only the models behind them differ.

**Ports follow device rank, not machine:** `8081` is always the primary GPU, `8082` the secondary
GPU, `8083` the NPU. The AMD desktop and the laptop's RTX both sit on 8081 because each is its
machine's primary GPU — they are separate hosts, so there is no conflict. A client pointed at
`:8081` gets the best GPU available wherever it is running. Same reasoning lets both machines'
LiteLLM run as `container_name: litellm` on port 4000.

**The laptop runs the nvidia and intel instances CONCURRENTLY** — `podman-compose -f
ai/llama-cpp.yml --profile laptop up -d`. They used to share `container_name: llama_swap_server`
and port 8081, which made them mutually exclusive; container name, ports and the config mount are
now set per-service instead of on the `base_llama_swap` anchor. Do not move them back into the
anchor.

### Measured performance (laptop, 6524-token prompt)

| tier | model | prefill | decode | footprint |
|---|---|---|---|---|
| RTX 5070 | `gemma-4-26b` (default) | 641 tok/s | 23 tok/s | 6883 MiB VRAM |
| RTX 5070 | `qwen3.5-9b` | **1932 tok/s** (3.4s) | **48 tok/s** | 6303 MiB VRAM |
| Arc iGPU | `gemma-4-e2b` (text-only, `--reasoning off`) | 194 tok/s (33.6s) | 16 tok/s | 2.62 GB RAM |
| Arc iGPU | `embed` (Qwen3-Embedding-0.6B) | — | — | 0.80 GB RAM |
| Intel NPU | `Qwen3-1.7B` | 33 tok/s | **0.61 tok/s** | system RAM |

**A 26B model runs on the 8GB card via `--n-cpu-moe`.** `gemma-4-26b-A4B` is MoE — 128 experts,
8 active per token, 30 layers — and ~88% of its 15.8GB of weights are expert tensors that most
tokens never touch. `--n-cpu-moe 26` keeps the expert tensors of the first 26 layers in system RAM
while attention, embeddings, norms and the KV cache stay on the GPU. The dense parts every token
needs are on the GPU; the sparse parts it skips are in RAM. Measured sweep (lower N = more on GPU
= faster but more VRAM): N=30 → 21.8 tok/s / 3621 MiB, **N=26 → 23.4 / 6883**, N=24 → 24.4 / 6529
(no mmproj), N=22 → 25.9 / 7435, **N≤18 → OOM**. N=26 is chosen to leave room for the vision
projector plus ~1.2GB headroom; N=22 buys ~10% for 2.5GB more VRAM and risks OOM on long prompts.

This is a deliberate capability-for-speed trade. A trivial Hermes turn takes **~39s** on
`gemma-4-26b` versus **~2.6s** on `qwen3.5-9b`. `qwen3.5-9b` stays in the config with no alias
pointing at it — request it by name when throughput matters more than capability. Doing so costs
a ~15s swap, since only one model fits in 8GB.

The dGPU wins on prefill by 3–10x, so **agent traffic belongs there** — agent prompts are
prefill-dominated. The iGPU is not a "medium speed" tier in any throughput sense. What it actually
buys, after vision moved off it, is narrow but real: it serves **embeddings** and cheap background
work **without evicting `gemma-4-26b`** from the 8GB card, which holds exactly one model. It is
*not* a useful parallel lane for delegation — see the measurement below.

### The alias contract

Semantic aliases are the interface agents use — **never hardcode a checkpoint name**, it will
break on the other machine. The alias NAMES are identical across machines; only the right-hand
side differs. This is what lets one shared `~/.hermes/config.yaml` drive either box.

| alias | laptop | desktop | use |
|---|---|---|---|
| `local-main` | `gemma-4-26b` (RTX 5070) | `qwen3.6-27b` (7900 XTX) | main agent, delegation, anything user-facing |
| `local-vision` | `gemma-4-26b` (RTX 5070) | `qwen3.6-27b` | images/PDFs — same model as `local-main`, so no swap |
| `local-tiny` | `gemma-4-e2b` (Arc iGPU) | `gemma-4-12b` | background/fire-and-forget side tasks; **no vision, no reasoning** |
| `local-embed` | `embed` (Arc iGPU) | **MISSING** | RAG embeddings, 1024-dim |

There is deliberately **no `local-support`**. It existed briefly, resolved to the same iGPU model
as `local-tiny`, and never had a consumer — two names for one thing is just a way to drift out of
sync. If background delegation ever needs its own tier, add the alias back to both litellm configs;
nothing in Hermes has to change.

> **Known asymmetry:** `local-embed` exists only on the laptop — the desktop has no embedding
> GGUF, so the alias is absent from `litellm-config.desktop.yaml`. Anything routed to
> `local-embed` will fail there. Either download an embedding model on the desktop and add the
> alias, or keep embedding consumers laptop-only. Do not "fix" this by pointing `local-embed` at
> a chat model — a chat deployment cannot serve `/v1/embeddings`.

**Delegation runs on `local-main`, not the secondary GPU — this is measured, not assumed.**

| delegate_task, identical prompt | wall time |
|---|---|
| `local-main` (RTX 5070, `gemma-4-26b`) | **33.6s** |
| the Arc iGPU (`gemma-4-e2b`) | 2m05.8s |

This was re-measured after `local-main` became `gemma-4-26b` (~2x slower than the `qwen3.5-9b`
originally tested) and the conclusion survived. Three reasons the "parallel lane" does not pay off:
during synchronous delegation the parent is idle so the primary GPU is free anyway (and the child
reuses the already-loaded model, no eviction); each llama-swap instance is `--parallel 1`, so
concurrent children serialize on the iGPU exactly as they would on the dGPU; and subagent cost is
**prefill-dominated** (large system prompt), where the iGPU does 194 tok/s against the dGPU's 641.
Decode rates are close (16 vs 23 tok/s) but that is not where the time goes. The iGPU wins only
for `background=true` delegation, where the parent really is generating at the same time.

## Hermes wiring (`~/.hermes/config.yaml`)

That file is **shared between both machines** and names only aliases. Relevant keys:

- `model.default: local-main` — the main agent.
- `delegation.model: local-main` — subagents (see measurement above). `provider`/`base_url`/
  `api_key` left empty so children inherit the parent's LiteLLM endpoint.
- `custom_providers[0].models.*.context_length` — pinned to **65536** for every alias. Without
  these, Hermes reads `*.context_length` from GGUF metadata and advertises the model's native
  window (e.g. 256K for Gemma 4), overrunning the actual `--ctx-size` KV allocation. Values are
  the **minimum across both machines**, so the shared file is safe either way.
- `auxiliary.<task>.{provider,model,base_url,api_key,timeout}` — 15 side tasks, each pinned.
  `base_url` is set explicitly on every one so they can never silently fall back to
  openrouter (no key is configured here).

Auxiliary tasks split on **critical path vs background**, not on prompt size:

| tier | tasks |
|---|---|
| `local-main` (dGPU) | `compression`, `web_extract`, `mcp`, `skills_hub`, `memory_query_rewrite`, `approval`, `triage_specifier`, `kanban_decomposer`, `goal_judge` |
| `local-vision` (dGPU) | `vision` |
| `local-tiny` (iGPU) | `title_generation`, `curator`, `profile_describer`, `monitor`, `tts_audio_tags` |

Anything the user waits on goes to `local-main` — it is faster *and* reuses the already-loaded
model. Fire-and-forget work goes to `local-tiny` on the iGPU specifically so it does **not** evict
`gemma-4-26b` from the 8GB card. Timeouts are raised well above Hermes' defaults (120s compression
/ 360s web_extract) because local models are slow and a timeout mid-compression drops context
rather than degrading gracefully.

**Hermes cannot consume `local-embed`.** There is no embedding config key anywhere in
`hermes_cli/config_defaults.py` and nothing in the agent calls `/embeddings`; its built-in memory
is not vector-based, and the external providers that do use embeddings (Hindsight) run
`sentence-transformers` locally rather than hitting an OpenAI-compatible endpoint. `local-embed`
is for the qdrant/n8n stack (`ai/n8n.yml`), `ai/research.yml`, or direct API use.

## Per-device notes

- **Intel iGPU (Arc)** — SYCL, via upstream-tracking `llama-swap:intel` image (`intel_llama_swap`
  profile). Runs two `llama-server` processes, **both resident simultaneously** via a `groups:`
  block with `swap: false`: `gemma-4-e2b` (`local-tiny` — text-only, `--reasoning off`) and
  `embed` (`local-embed`). RAG and background calls interleave constantly, so letting them evict
  each other would add a reload to every switch. Measured resident total **3.41 GB**
  (2.62 + 0.80) against 62GB of system RAM. `gemma-4-e4b` was dropped: on this bandwidth-bound iGPU, e2b is faster at
  everything (194 vs 146 tok/s prefill, 16 vs 10 tok/s decode) and equally vision-capable, so e4b
  cost latency for nothing.
  **Cold-start gotcha:** the `intel_sycl_cache` named volume (mounted at `/root/.cache`) persists
  the SYCL/Level-Zero JIT kernel cache across container restarts. Without it, every recreate
  recompiles all GPU kernels from scratch — measured 4m32s for the first request after a fresh
  volume vs. 18s once warm. If iGPU requests look "stuck"/timed-out right after `up`, that's this,
  not a broken deployment — wait it out once, or warm it manually before sending real traffic:
  `curl -s localhost:8082/v1/chat/completions -d '{"model":"gemma-4-e2b","messages":[{"role":"user","content":"hi"}],"max_tokens":8}'`.
  Client-side timeouts (LiteLLM, OpenAI SDKs) are often shorter than the cold-compile time, so the
  first real request can look like total failure (200 response, 0-byte body) even though the
  backend is fine — it just hadn't finished compiling yet.
  The Intel image also **crashes on `--help` without a GPU device** (SYCL init failure), so read
  flag documentation from the `:cuda` image instead.
- **Intel NPU (EXPERIMENTAL, not routed)** — `intel_npu_llama_cpp` profile,
  `intel_npu_llama_server` service. Standalone `llama-server` (no llama-swap integration exists for
  the OpenVINO backend yet), one fixed model (`Qwen3-1.7B-Q4_0.gguf`), host port 8083, `-c 1024`.
  At 0.61 tok/s decode a 24-token tool call took 39s, versus ~7s warm on the iGPU. Tool calling
  *does* work (correct arguments, `finish_reason: tool_calls`) — the limit is throughput, not
  capability. No litellm config routes to it. Reach it directly on `localhost:8083`.
  Can run alongside either GPU tier since it uses a separate device (`/dev/accel`) — but the iGPU
  and NPU share the same LPDDR5x bus as the CPU, so running both concurrently slows both. They are
  not independent throughput adders. See `ai/LLAMA-CPP.md` for the measurements.

Request flow: agents → LiteLLM (`:4000`) → the appropriate llama-swap instance (`:8081` primary
GPU / `:8082` iGPU on the host) → spawned `llama-server` subprocess per model. LiteLLM also routes
to cloud (Anthropic/Gemini). Model GGUFs live in `${LLAMA_MODELS_DIR:-~/.llama/models}` (host),
mounted to `/models` — export `LLAMA_MODELS_DIR` before `podman-compose up` to point elsewhere
(this laptop uses `/mnt/data/llama/models`).

## Vision / mmproj — the #1 gotcha

Each vision model needs the multimodal projector built for **its own embedding dim**. Projectors
are **not** interchangeable across model sizes. A mismatch makes `llama-server` abort on load:
`mismatch between text model (n_embd=X) and mmproj (n_embd=Y)`.

This fails **silently** until first use: llama-swap spawns the subprocess on demand, so a
misconfigured model looks fine until an agent actually requests it, then crashes with
`upstream command exited prematurely` / `connection refused`.

Gemma 4 embedding dims are all distinct → one projector per model, no sharing:

| model | n_embd | native ctx | projector file | in use |
|---|---|---|---|---|
| gemma-4-12b | 3840 | 256K | `gemma-4-12b-mmproj-F16.gguf` | desktop |
| gemma-4-26b | 2816 | 256K | `gemma-4-26b-mmproj-F16.gguf` | **laptop `local-vision`** + desktop |
| gemma-4-e4b | 2560 | 128K | `gemma-4-e4b-mmproj-F16.gguf` | no longer used |
| gemma-4-e2b | 1536 | 128K | `gemma-4-e2b-mmproj-F16.gguf` | **not loaded** — removed from the tiny tier |

Qwen 3.6 27b and 35b likewise use their own per-model projectors.

**Adding a vision model:** read the GGUF `*.embedding_length` metadata, then fetch the projector
from *that exact model's* Unsloth `*-GGUF` repo (file is `mmproj-F16.gguf`), saved as
`<model>-mmproj-F16.gguf`. Never reuse another size's projector.

**`local-vision` has NO fallback on the laptop, deliberately.** `gemma-4-26b` is the only model
there with a projector — `gemma-4-e2b`'s was removed and `qwen3.5-9b` never had one. Falling back
to either would mean a blind model confidently describing an image it cannot see, which is worse
than a clean error. If the dGPU is down, vision fails loudly. That is the intended behaviour.

## The tiny tier: no vision, no reasoning

Every model here is a thinking model, which is actively harmful for `local-tiny` work. Measured on
a realistic title-generation prompt (the answer was the same three-word title in every case):

| configuration | completion tokens | reasoning leaked into `content`? |
|---|---|---|
| default (thinking on) | 302 (~40s) | no — but ~290 tokens wasted |
| `--reasoning-budget 0` | 358 | **YES** |
| `--reasoning off` | **107–111 (~17s)** | no |

Three traps, all of which fail silently rather than erroring:

1. **`--reasoning-budget 0` is not an off switch.** It suppresses thought-tag *parsing* only — the
   model still reasons, and the trace lands in `message.content`. Session titles come back reading
   `"Thinking Process:\n\n1. **Analyze the conversation**..."`. It measured *worse* than leaving
   thinking on. Use `--reasoning off`.
2. **Per-request `reasoning_effort` does not work through LiteLLM.** Sent straight to llama-server
   it works perfectly (108 tokens, zero reasoning). Sent through the gateway with the identical
   body it is **silently dropped** — 310 tokens with full reasoning, indistinguishable from not
   sending it, and no warning anywhere. `drop_params: true` strips it for `openai/`-prefixed custom
   endpoints. This is why thinking has to be turned off at the *server*, not per call.
3. Reasoning is a **server-level** flag, so it has to be set on the process, not the request.
   There was briefly a second `llama-server` over the same GGUF (`gemma-4-e2b-fast`) so that
   `local-support` could keep thinking while `local-tiny` did not; that is gone now that
   `local-support` is gone. One process, `--reasoning off`.

**Vision is also removed from this tier.** The `--mmproj` was dropped: `local-vision` resolves to
`gemma-4-26b` on the dGPU, which has its own projector and is a far better vision model, so the
~1GB projector here served nothing. `gemma-4-e2b` now correctly rejects images with
`image input is not supported - hint: if this is unexpected, you may need to provide the mmproj`.
It remains vision-*capable* — re-add `--mmproj /models/gemma-4-e2b-mmproj-F16.gguf` (n_embd 1536,
that exact file) to restore it.

Dropping the second process and the projector took the iGPU tier from **6.06 GB to 3.41 GB**
resident.

## Embeddings

`embed` = `Qwen3-Embedding-0.6B-Q8_0.gguf`, 1024-dim, 28 layers, native ctx 32768. Served on the
iGPU. Two non-obvious constraints:

- **`--pooling last`, NOT `mean`.** The GGUF declares `pooling_type: 3` (LAST) — Qwen3-Embedding
  derives the sentence vector from the final token rather than averaging. Passing `mean` produces
  degraded embeddings that still look plausible: unit-norm vectors, no error, just worse retrieval.
  llama.cpp uses the model default when `--pooling` is omitted; it is stated explicitly so nobody
  "corrects" it later. Sanity check after any change — related pairs must separate from unrelated
  ones (measured: `cat~kitten` 0.673, `db~sql` 0.809, `cat~db` 0.308, `kitten~sql` 0.204).
- **`--ubatch-size` must be ≥ the longest input.** With pooling enabled the whole sequence has to
  fit in a single ubatch, so ubatch is pinned to `--ctx-size` (8192). That covers any realistic RAG
  chunk (typically 512–1024) without sizing the compute buffer for the full 32768 window.

This server is **embeddings only** — it cannot serve `/v1/chat/completions`.

## Build-specific facts

The three images (`llama-swap:rocm` desktop, `:cuda` and `:intel` laptop) track upstream
llama.cpp and behave the same on these points:

- `--jinja` is **enabled by default** — do not add it; chat templates + reasoning extraction work.
- `--flash-attn` needs an explicit value: `--flash-attn on`.
- Qwen 3.6 is supported out of the box — the "must build from source for Qwen3.6 rope" advice from
  older guides does **not** apply.
- Available and used: `--cache-reuse`, `--batch-size`/`--ubatch-size`, `--cache-type-k/v`,
  `--n-cpu-moe`, `--pooling`, `--embedding`, `--reasoning`, per-model sampling flags.

## Context: metadata vs runtime

Clients read `*.context_length` from GGUF metadata and advertise the model's **native training
context** (e.g. Gemma 4 26b = 262144 / 256K), regardless of the runtime `--ctx-size` cap. The
actual KV allocation is whatever `--ctx-size` sets. For Hermes this is no longer cosmetic — it is
pinned explicitly per alias in `custom_providers[0].models` (see the Hermes section). When
changing a model's `--ctx-size`, update that map too, and remember the runtime window must cover
the **largest** alias pointing at that model.

## Tuning conventions in this config

- All models `--parallel 1` so `--ctx-size` is the full per-request window.
- 24GB tier: `q8_0` KV cache, `--ubatch-size` raised (2048 for the small-weight 12b, 1024 for the
  ~17GB models) for prefill throughput. Verify VRAM with `rocm-smi` after changing batch sizes;
  if a 17GB model OOMs, drop its `--ubatch-size` back to 512.
- 8GB dGPU tier (`llama-swap-nvidia.yaml`): `q4_0` KV cache — 8GB is a hard wall here.
  `qwen3.5-9b` at 64K + `--ubatch-size 512` measures 6303 MiB of 8151 MiB, ~1.8GB headroom;
  `gemma-4-26b` at 64K with `--n-cpu-moe 26` + mmproj measures 6883 MiB, ~1.2GB headroom.
  Fallback levers if `qwen3.5-9b` OOMs: `--ubatch-size` 512 → 384 → 256, *then* `--ctx-size`
  64K → 32K. For `gemma-4-26b`, raise `--n-cpu-moe` instead (26 → 28 → 30) — that trades decode
  speed for VRAM without touching context.
- iGPU tier (`llama-swap-intel.yaml`): `q8_0` KV and much larger batches than the dGPU tier,
  because the Arc iGPU has **no dedicated VRAM** — it allocates from 62GB of system RAM, so the
  8GB-tier concessions buy nothing there. Measured ubatch sweep on a 6524-token prefill:
  128 → 104 tok/s, 512 → 126, **1024 → 146 (best)**, 2048 → 136 (overshoots, regresses).
  The ceiling is memory bandwidth, not batch size: an 8x ubatch increase bought only ~40%.
  Do not expect more from further tuning here.
  **Memory caveat:** the Arc iGPU reports free memory tracking host `MemFree`, not reclaimable
  `MemAvailable`. If a model fails to allocate, check `free -h` before lowering ubatch. With all
  three iGPU processes resident, `MemFree` sits around 1.5-2 GiB while `MemAvailable` is ~27 GiB —
  the low number is page cache, not exhaustion, but it is close enough to the documented failure
  mode to be worth watching if you add a fourth model here.
- Per-model sampling baked in as defaults (Qwen: temp 0.7/top-k 20/top-p 0.95/min-p 0;
  Gemma: temp 1.0/top-k 64/top-p 0.95). Clients can override per request.
- `--n-cpu-moe` IS used, on `gemma-4-26b` only — it is what makes a 26B model fit 8GB (see above).
  It composes with `--n-gpu-layers 99`: ngl decides layer placement, `--n-cpu-moe` overrides it for
  expert tensors only. Useless on dense models like `qwen3.5-9b`, which have no expert tensors.
- `groups:` with `swap: false` keeps multiple models resident in one instance. Used on the iGPU
  (`gemma-4-e2b` + `embed`). **Not** usable on the 8GB dGPU — `gemma-4-26b` and `qwen3.5-9b`
  cannot co-reside, so switching between them is an inherent ~15s swap.
- Deliberately not used: `--mlock` (fights llama-swap's TTL load/unload).

## Testing / verification

```bash
# direct to a llama-swap instance (bypasses LiteLLM) — fastest way to smoke-test a model loads
curl -s localhost:8081/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"gemma-4-26b","messages":[{"role":"user","content":"hi"}],"max_tokens":400}'   # dGPU
curl -s localhost:8082/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"gemma-4-e2b","messages":[{"role":"user","content":"hi"}],"max_tokens":400}'   # iGPU
curl -s localhost:8082/v1/embeddings -H 'Content-Type: application/json' \
  -d '{"model":"embed","input":"test"}'                                                       # iGPU

# confirm thinking is really off on the tiny tier — `reasoning` must be 0.
# Use a WELL-SPECIFIED prompt: given a vague one e2b rambles to the max_tokens cap
# either way and the contrast disappears. Expect ~101 tokens, reasoning 0.
P='Generate a short title (max 6 words) for this conversation:\nUser: my postgres container keeps OOMing after about an hour\nAssistant: Lets check shared_buffers and work_mem first.'
curl -s localhost:8082/v1/chat/completions -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg p "$P" '{model:"gemma-4-e2b",messages:[{role:"user",content:$p}],max_tokens:400}')" \
  | jq '{tokens:.usage.completion_tokens, reasoning:(.choices[0].message.reasoning_content // "" | length)}'

# confirm vision is really gone from the tiny tier — must error, not answer
curl -s localhost:8082/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"gemma-4-e2b","messages":[{"role":"user","content":[{"type":"text","text":"what is this?"},{"type":"image_url","image_url":{"url":"data:image/png;base64,iVBORw0KGgo="}}]}],"max_tokens":50}' \
  | jq -r '.error.message // "UNEXPECTED: answered instead of erroring"' 

# aliases through the gateway (what agents actually use)
curl -s localhost:4000/v1/chat/completions -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"local-main","messages":[{"role":"user","content":"hi"}],"max_tokens":400}'

# which models are loaded right now, per tier
curl -s localhost:8081/v1/models | jq '[.data[] | {id, status: .status.value}]'
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
`InternalServerError - Connection error`. `request_timeout: 600` is set in both litellm configs;
don't lower it.

**LiteLLM fallbacks are matched on the requested name, not the resolved one.** A request for the
alias `local-vision` does *not* inherit a fallback declared for `gemma-4-e2b` — it fails with
`No fallback model group found for original model_group=local-vision`. Every alias needs its own
entry in the `fallbacks` list; they are there, keep them in sync when adding aliases.

**Do not list one machine's models in the other's litellm config.** The laptop config previously
carried the desktop's five entries pointing at `llama_swap_server` (unreachable from the laptop),
and once the laptop gained its own `gemma-4-26b` deployment that became a duplicate `model_name` —
LiteLLM would have load-balanced across a live and a dead endpoint. Each config lists only what its
own machine can serve.
