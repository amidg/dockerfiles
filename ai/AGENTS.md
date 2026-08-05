# AGENTS.md — local LLM stack

Everything non-obvious about this stack lives here. Read before editing any config.

## Document structure — where things belong

| file | contains | audience |
|---|---|---|
| `README.md` | how to run it, endpoints, aliases, a handful of headline numbers | humans |
| `AGENTS.md` | **all rules, rationale and accumulated learnings** | agents + whoever edits configs |
| `*.yml`, `*.yaml` | **working config only — no comments** | the runtime |

The benchmark harness lives in a **separate repo**,
[amidg/llm-benchmarking](https://github.com/amidg/llm-benchmarking) (`smoke.py`,
`llmbench.py`). It has its own `AGENTS.md` covering how to run it and how to avoid drawing
wrong conclusions from its output. Point it at this stack with
`export LITELLM_ENV=~/Projects/dockerfiles/ai/litellm.env`.

**Configs carry no comments by design.** Rationale rots when it sits next to the flag it
explains; it gets copied, contradicted, and never re-measured. If a setting needs
justifying, justify it here with the measurement that produced it. If you change a tuned
value, update the table here in the same commit.

## Architecture

Two machines. Each llama-swap instance mounts one config and advertises only what its
device can run.

| config | container | device | port | models |
|---|---|---|---|---|
| `llama-swap-nvidia.yaml` | `llama_swap_nvidia` | RTX 5070 8GB (laptop) | 8081 | `qwen3.6-35b` (default), `gemma-4-26b`, `qwen3.5-9b` |
| `llama-swap-intel.yaml` | `llama_swap_intel` | Arc Pro iGPU (laptop) | 8082 | `qwen3.5-2b`, `embed` |
| `llama-swap-config.yaml` | `llama_swap_server` | 7900 XTX 24GB (desktop) | 8081 | `qwen3.6-27b`, `gemma-4-12b`, `gemma-4-26b`, `qwen3.6-35b`, `qwen3-coder-30b` |

**Ports follow device rank, not machine:** 8081 = primary GPU, 8082 = secondary, 8083 =
NPU. The desktop and laptop both use 8081 because each is its machine's primary GPU; they
are separate hosts. Same reasoning lets both run `container_name: litellm` on 4000.

**The laptop runs nvidia + intel concurrently.** They used to share a container name and
port via the `base_llama_swap` anchor, which made them mutually exclusive. `container_name`,
`ports` and the config mount are per-service now — do not move them back into the anchor.

Request flow: agents → LiteLLM (`:4000`) → llama-swap (`:8081`/`:8082`) → a `llama-server`
subprocess per model. GGUFs live in `${LLAMA_MODELS_DIR:-~/.llama/models}`, mounted at
`/models` (this laptop: `/mnt/data/llama/models`).

## The alias contract

Semantic aliases are the interface agents use. **Never hardcode a checkpoint name** — it
breaks on the other machine. Alias names are identical everywhere; only the right-hand
side differs. This is what lets one shared `~/.hermes/config.yaml` drive either box.

| alias | laptop | desktop | use |
|---|---|---|---|
| `local-main` | `qwen3.6-35b` | `qwen3.6-27b` | main agent, delegation, anything user-facing |
| `local-vision` | `qwen3.6-35b` | `qwen3.6-27b` | images/PDFs — same model as `local-main`, so no swap |
| `local-tiny` | `qwen3.5-2b` (iGPU) | `gemma-4-12b` | background/fire-and-forget; **no vision, no reasoning** |
| `local-embed` | `embed` (iGPU) | **missing** | RAG embeddings, 1024-dim |

Models with no alias (`gemma-4-26b`, `qwen3.5-9b`) are reachable by name; requesting one
evicts the loaded model (~15-30s) since only one fits in 8GB.

- **`local-embed` is laptop-only.** The desktop has no embedding GGUF. Do not "fix" this
  by pointing it at a chat model — a chat deployment cannot serve `/v1/embeddings`.
- **There is deliberately no `local-support`.** It existed, resolved to the same iGPU
  model as `local-tiny`, and had no consumer. Two names for one thing drift apart.
- **`local-vision` must never fall back to a model without a projector.** A blind model
  confidently describing an image is worse than a clean error. Both `qwen3.6-35b` and
  `gemma-4-26b` carry projectors, so vision degrades between them.

## Measured performance (laptop)

Absolute values drift 20-30% with load and thermals — **only compare models measured in
the same session.** Ratios have been stable across every repetition.

| device | model | prefill | decode (deep) | VRAM |
|---|---|---|---|---|
| RTX 5070 | `qwen3.6-35b` **(default)** | 411-454 t/s | **31.4 t/s** (36.6 shallow) | 6947 MiB |
| RTX 5070 | `gemma-4-26b` | 616 t/s | 17.9 t/s *(pre-`deep`, stale)* | 6903 MiB |
| RTX 5070 | `qwen3.5-9b` | 1932 t/s | 48 t/s *(stale)* | 6303 MiB |
| Arc iGPU | `qwen3.5-2b` | 558 t/s | 23.1 t/s *(stale)* | 1.34 GB RAM |
| Arc iGPU | `embed` | — | — | 0.80 GB RAM |
| Intel NPU | `Qwen3-1.7B` | 33 t/s | 0.61 t/s | RAM |

### Decode is two numbers, and mixing them wastes days

- **shallow** — generation from a fresh short prompt (~0 context). The `tg128`-equivalent,
  and what almost every figure quoted online means.
- **deep** — generation continuing from a ~6.5K prefill. What an agent turn actually does,
  because Hermes sends a large system prompt every time.

**Judge an agent tier on `deep`.** This table once recorded `qwen3.6-35b` at 14.9 t/s;
re-measured on the *unchanged* config it was 29.3 deep / 33.5 shallow. The old number was
a hand-measured deep figure from before `bench/` existed and was never comparable to
anything since — it triggered an entire optimisation effort against a problem that did not
exist. Rows marked *stale* above may have the same defect.

## Running 26B/35B models on an 8GB card

Both large models are MoE, and ~90% of their weights are expert tensors any given token
never touches. `--n-cpu-moe N` keeps the expert tensors of the first N layers in system
RAM while attention, embeddings, norms and KV stay on the GPU. It composes with
`--n-gpu-layers 99` (ngl places layers, `--n-cpu-moe` overrides for expert tensors only)
and does nothing on dense models.

| model | layers | experts | quant | N |
|---|---|---|---|---|
| `qwen3.6-35b` | 40 | 256 / 8 active | UD-Q4_K_M (22.1 GB) | **34** |
| `gemma-4-26b` | 30 | 128 / 8 active | UD-Q4_K_XL (15.8 GB) | **26** |

### N does not buy deep decode — tune it for VRAM headroom

Measured on `qwen3.6-35b` UD-Q4_K_M at `--threads 6`, everything else fixed:

| N | mmproj | prefill | shallow | **deep** | VRAM |
|---|---|---|---|---|---|
| **34** | yes | 454 t/s | 37.2 | **31.4** | 6947 MiB |
| 33 | yes | 461 t/s | 37.3 | **31.8** | ~7452 MiB |
| 31 | no | 483 t/s | 38.8 | **31.7** | ~6100 MiB |

Moving **three** expert layers onto the GPU changed deep decode by 0.3 t/s — noise.
Shallow decode and prefill do respond; the number an agent experiences does not, because
the shallow→deep gap is attention work at context, which expert placement cannot touch.

So prefer the **higher** N that preserves vision headroom. N=34 costs ~0.4 t/s against
N=33 and buys 470 MiB of margin against the vision crash.

### `qwen3.6-35b` is a hybrid, so context is cheap

`full_attention_interval: 4` — only **10 of 40 layers** carry a KV cache; the rest are
SSM/Mamba blocks with constant state. KV at 64K with `q4_0` is ~360 MiB. Halving
`--ctx-size` frees under 200 MiB, so **context reduction is not a VRAM lever here.**

### CPU thread count: fewer, faster threads win

`--n-cpu-moe` puts ~92% of weights on the CPU, so decode is gated by CPU expert
dequant+gather. Topology: `0-5` P-cores 5400 MHz, `6-13` E-cores 4500 MHz, `14-15` LP-E
2500 MHz.

| `--threads` / affinity | prefill | shallow | **deep** |
|---|---|---|---|
| unset (spawns 16) | 448 t/s | 34.2 | 30.5 |
| `14 --cpu-range 0-13 --cpu-strict 1` | 455 t/s | 25.0 | 22.3 |
| `12 --cpu-range 0-11 --cpu-strict 1` | 453 t/s | 25.0 | 22.2 |
| `8 --cpu-range 0-7 --cpu-strict 1` | 453 t/s | 33.7 | 26.8 |
| **`6 --cpu-range 0-5 --cpu-strict 1`** | 453 t/s | **36.9** | **31.6** |

**The obvious hypothesis is wrong.** "The two 2500 MHz LP-E cores gate llama.cpp's per-op
barrier, so exclude them" predicts `-t 14` wins. It is the second-*worst* setting tested,
below leaving all 16 unpinned. The real rule is fewer, faster threads: the expert gather
is synchronisation-bound, not throughput-bound, so mid-speed cores cost more in barrier
overhead than they add.

**Prefill is flat (448-455) across every setting** because it is GPU-bound. Never tune
threads on a prefill number.

### Quant choice for CPU-offloaded MoE

Head-to-head at identical threads, same session, 3 rounds:

| quant | prefill | shallow | deep | VRAM |
|---|---|---|---|---|
| **UD-Q4_K_M** | 411 t/s | 36.6 | **31.4** | 6985 MiB |
| UD-Q4_K_XL | 408 t/s | 35.6 | 30.4 | 7103 MiB |

Small but consistent every round, for 118 MiB less VRAM. Earlier, `UD-IQ4_XS` (17.7 GB)
lost to `UD-Q4_K_XL` on decode (10.0 → 14.9) while winning prefill (535 → 395): i-quant
dequantisation is markedly more expensive on the CPU, which is where the experts live, but
the smaller file fits two more expert layers on the GPU and prefill activates many experts
per batch. **Prefer K-quants for CPU-offloaded MoE**, and re-tune N *and* re-measure both
axes after any quant change. IQ4_XS remains the pick only for huge-prompt/terse-output
work; the file is still on disk.

**File size alone does not predict VRAM.** Non-expert tensors are always GPU-resident, and
quant recipes differ in how they treat them. Unsloth's Q4_K_XL and Q4_K_M both keep
`attn_qkv`/`ssm_out` at Q8_0 (2.68 vs 2.56 GB non-expert), but a third-party Q4_K_M of the
same model used Q5_K/Q4_K there — 1.65 GB, freeing ~983 MiB. Read the tensor table before
predicting.

### The vision floor moves with the quant, and text tests will not find it

`qwen3.6-35b` on Q4_K_XL survived images at 7539 MiB and **crashed at 7743** (`upstream
process exited unexpectedly`, HTTP 502, process gone). The older IQ4_XS build crashed at
N=30 for the same reason: ~600 MiB of headroom cannot supply the vision encoder's compute
buffer.

**Every crashing configuration passes a full 6524-token text prefill.** Always send an
image after re-tuning `--n-cpu-moe` on a model with `--mmproj`.

## Vision / mmproj — the #1 gotcha

Each vision model needs the projector built for **its own embedding dim**. Projectors are
not interchangeable. A mismatch aborts with `mismatch between text model (n_embd=X) and
mmproj (n_embd=Y)` — and only on the **first image request**, not at load, because
llama-swap spawns the subprocess on demand.

| model | n_embd | projector |
|---|---|---|
| qwen3.6-35b | 2048 | `qwen3.6-35b-mmproj-F16.gguf` |
| gemma-4-26b | 2816 | `gemma-4-26b-mmproj-F16.gguf` |
| gemma-4-12b | 3840 | `gemma-4-12b-mmproj-F16.gguf` |

Adding one: read the GGUF `*.embedding_length`, then fetch `mmproj-F16.gguf` from *that
exact model's* Unsloth repo. Never reuse another size's projector.

## Splitting a model across both GPUs with Vulkan — tested, rejected (2026-08-05)

The intuition is compelling and will be proposed again. `--n-cpu-moe` makes the *CPU* do
the expert gather; the laptop also has an Arc iGPU, so use it instead.

**It is mechanically possible and RPC is not needed** — one Vulkan process drives both
GPUs. (Neither `:cuda` nor `:intel` ships `rpc-server`, `libggml-rpc.so` or `--rpc`, so
the RPC route would have meant building both sides.)

```bash
podman run --rm --device /dev/dri --device nvidia.com/gpu=all \
  --security-opt label=disable --group-add 105 --group-add 39 \
  --entrypoint /app/llama-server ghcr.io/mostlygeek/llama-swap:vulkan --list-devices
#   Vulkan0: Intel(R) Graphics (ARL)          (47779 MiB, 30480 MiB free)
#   Vulkan1: NVIDIA GeForce RTX 5070 Laptop   (8151 MiB,  6718 MiB free)
```

- **`--security-opt label=disable` is mandatory.** CDI injects the NVIDIA Vulkan ICD at
  `/etc/vulkan/icd.d/`, but SELinux blocks the driver it points at and **only the Arc
  enumerates**. Tell-tale: `Could not get 'vkCreateInstance' via
  'vk_icdGetInstanceProcAddr' for /usr/lib64/libGLX_nvidia.so.0`.
- **`--tensor-split` is the wrong tool for MoE** — it divides *layers*, putting half the
  attention and KV on the Arc. The MoE-correct split is
  `-dev Vulkan1,Vulkan0 -sm layer -ts 1,0 -mg 0 -ngl 99 -ot 'ffn_.*_exps=Vulkan0'`.
- **`-sm none` fails**: it deactivates the Arc backend and the load aborts with
  `pre-allocated tensor (blk.0.ffn_down_exps.weight) in a buffer (Vulkan0) that cannot run
  the operation (NONE)`. Both devices must stay active; `-ts 1,0` keeps layers on the dGPU.

Placement worked exactly as designed — dGPU held only 2505 MiB, ~19.6 GB of experts on the
Arc. The measurement (UD-Q4_K_M, 8665-token prefill, warm):

| config | prefill | decode |
|---|---|---|
| CUDA dGPU + CPU experts | **425 t/s** | **29.3 t/s** |
| Vulkan dGPU + CPU experts *(diagnostic)* | 224.8 t/s | 9.67 t/s |
| Vulkan dGPU + **Arc** experts | 135.5 t/s | 12.00 t/s |

```
CUDA -> Vulkan   (expert device held at CPU)   prefill -47%   decode -67%
CPU  -> Arc      (backend held at Vulkan)      prefill -40%   decode +24%
```

**The Arc really does beat the CPU at expert gather (+24% decode).** But Vulkan costs 67%
of decode first, so it nets to 12.0 vs 29.3 — 2.4x slower than doing nothing. The Arc also
*hurts* prefill, consistent with its known weakness at expert gathers.

Two structural reasons it was never going to pay:

- **The Arc is not a second memory pool.** Its "47779 MiB" is system RAM on the same
  LPDDR5x bus the CPU uses. It adds a compute unit, not bandwidth.
- **CUDA is worth more than the iGPU**, and any dual-GPU scheme here must go through
  Vulkan because CUDA cannot see the Intel device — so it pays -67% before it starts.

**The diagnostic row is the lesson.** Comparing only the incumbent against the proposal
changes backend *and* expert device at once and cannot say why the number moved. Always
include the config that varies one.

**Memory trap:** the Arc allocates against `MemFree`, not `MemAvailable`. Holding ~19.6 GB
of experts there drove the host to 529 MiB free with zram swap full, and **the whole
llama-swap stack was killed**. Tear down test containers before diagnosing a "hang".

## Speculative decoding and MTP

**No MTP support.** There is no `--mtp` flag; every `--spec-draft-*` option needs a
separate draft model file. Unsloth's `MTP-GGUF` variants carry weights this build cannot
activate — a bigger download for identical speed.

Classic speculative decoding does work, but the draft model's **vocabulary must match the
target**, and the drafter competes for the ~1.1 GB of dGPU headroom (`--spec-draft-ngl` /
`--spec-draft-n-cpu-moe` can place it). A real experiment, not a free win. Worth
revisiting after a llama.cpp upgrade — decode here is memory-bound, the regime where it
pays most.

## The tiny tier (Arc iGPU)

### Dense beats sparse here

Same iGPU, 64K ctx, 6524-token prefill, interleaved rounds:

| model | file | prefill | decode |
|---|---|---|---|
| **`qwen3.5-2b` (current)** | **1.28 GiB** | **557.7 t/s** | **23.1 t/s** |
| `Qwen3.5-4B` (rejected) | 2.71 GiB | 221.0 t/s | 11.9 t/s |
| `gemma-4-e2b` (replaced) | 3.00 GiB | 176.1 t/s | 16.3 t/s |
| `gemma-4-e4b` (rejected) | 4.80 GiB | 141.2 t/s | 10.4 t/s |
| `qwen3.5-9b` (rejected) | 5.60 GiB | 190.9 t/s | 7.4 t/s |

The gemma E-series are MoE and their expert gathers are inefficient on this device; a
dense 2B saturates it far better. Even dense `qwen3.5-9b` out-prefilled the 2B-active MoE.
**At the small end on this hardware, prefer dense.**

Capability was verified equal, not assumed: single call, selection among four schemas,
tool-result round-trip, and correctly declining. `qwen3.5-2b` also returns clean JSON where
`gemma-4-e2b` wrapped it in ``` fences. It retrieved a needle at 60% depth in 49,970 tokens.

### Context scaling — why this tier is not for big prompts

| context | prefill | time to ingest |
|---|---|---|
| 6.5K | 558 t/s | 12s |
| 19K | 252 t/s | 75s |
| 50K | 103 t/s | **485s** |

The dGPU holds ~396 t/s at 19K. **Small prompts → iGPU; large prompts → dGPU**, crossover
around 10-15K.

### No reasoning, no vision — both deliberate

| configuration | completion tokens | reasoning leaked into `content`? |
|---|---|---|
| default (thinking on) | 302 (~40s) | no — but ~290 wasted |
| `--reasoning-budget 0` | 358 | **YES** |
| **`--reasoning off`** | **101-111 (~17s)** | no |

1. **`--reasoning-budget 0` is not an off switch.** It suppresses thought-tag *parsing*
   only — the model still reasons and the trace lands in `content`, so titles come back as
   `"Thinking Process:\n\n1. **Analyze the conversation**..."`. It measured *worse* than
   leaving thinking on.
2. **Per-request `reasoning_effort` does not survive LiteLLM.** Sent straight to
   llama-server it works (108 tokens, zero reasoning); through the gateway it is
   **silently dropped** by `drop_params: true` (310 tokens, full reasoning, no warning).
   Reasoning must be off at the *server*.
3. **Unsloth's docs are wrong** about the Qwen3.5 Small series defaulting to reasoning off.
   Without the flag the 2B emitted ~1388 chars of reasoning and hit the cap with empty
   content. `--reasoning off` is required.
4. **`presence_penalty` 1.5-2.0 (Unsloth's recommendation) destabilises short factual
   output.** At temp 0.7 + pp 1.5 the 2B answered "17 times 4" as **56**; at temp 0, 68.
   The config uses 0.5.

Caveat: `--reasoning off` removes reasoning waste, not verbosity. A vague prompt still
rambles to the cap; a well-specified one ("Reply with ONLY the title") answers in ~8
tokens. Chattiness once blamed on `gemma-4-e2b` was a **prompt** problem.

Vision is absent because `local-vision` resolves to the dGPU's far better model. The tier
correctly rejects images with `image input is not supported`.

## Embeddings

`embed` = `Qwen3-Embedding-0.6B-Q8_0.gguf`, 1024-dim, 28 layers, native ctx 32768.

- **`--pooling last`, NOT `mean`.** The GGUF declares `pooling_type: 3` (LAST) —
  Qwen3-Embedding derives the sentence vector from the final token. `mean` produces
  degraded embeddings that still look plausible: unit-norm, no error, worse retrieval.
  Sanity check after any change — related pairs must separate from unrelated
  (`cat~kitten` 0.673, `db~sql` 0.809, `cat~db` 0.308, `kitten~sql` 0.204).
- **`--ubatch-size` must be ≥ the longest input.** With pooling the whole sequence must fit
  one ubatch, so it is pinned to `--ctx-size` (8192) — covers any realistic RAG chunk
  without sizing the compute buffer for the full 32768 window.

**Embeddings only** — this server cannot serve `/v1/chat/completions`.

## Per-device notes

**Intel iGPU (Arc)** — SYCL via the upstream-tracking `:intel` image. Runs `qwen3.5-2b` and
`embed` **both resident** via `groups:` with `swap: false`; RAG and background calls
interleave constantly, so eviction would add a reload to every switch. ~2.14 GB total.

- **Cold-start:** the `intel_sycl_cache` volume (`/root/.cache`) persists the SYCL/Level-Zero
  JIT kernel cache. Without it every recreate recompiles all kernels — measured **4m32s**
  for the first request vs 18s warm. Client timeouts are usually shorter than that, so the
  first request after `up` can look like total failure (200 response, 0-byte body) while
  the backend is fine.
- **`--help` crashes without a GPU device** (SYCL init failure). Read flag docs from `:cuda`.
- **Memory:** reports free memory tracking host `MemFree`, not reclaimable `MemAvailable`.
  Check `free -h` before lowering ubatch.
- **ubatch sweep** (6524-token prefill): 128 → 104 t/s, 512 → 126, **1024 → 146 (best)**,
  2048 → 136 (regresses). The ceiling is bandwidth, not batch size — an 8x increase bought
  ~40%. The old value of 128 was an 8GB-tier concession that buys nothing here, same for
  `q8_0` KV instead of `q4_0`.

**Intel NPU (experimental, not routed)** — `intel_npu_llama_cpp` profile, standalone
`llama-server` on the OpenVINO backend (no llama-swap integration exists), `Qwen3-1.7B-Q4_0`,
port 8083, `-c 1024`. **0.61 t/s decode** — a 24-token tool call took 39s vs ~7s warm on the
iGPU, ~21x slower on a model 2.4x smaller. Tool calling *does* work (correct arguments,
`finish_reason: tool_calls`); the limit is throughput, not capability. Stateless only, no
`--parallel > 1`, Q4_0-oriented quant. No image exists upstream — build from
`.devops/openvino.Dockerfile` with the llama.cpp repo as build context:

```bash
podman build -t localhost/llama-cpp-openvino:server-5d8ccdf \
  -f .devops/openvino.Dockerfile --target server \
  "https://github.com/ggml-org/llama.cpp.git#5d8ccdf9d1273bfd83ad8f72565885acc450997e"
```

The iGPU and NPU share the LPDDR5x bus with the CPU — running both concurrently slows
both. **They are not independent throughput adders.**

## llama.cpp build facts

The images (`:rocm`, `:cuda`, `:intel`, `:vulkan`) track upstream and agree on:

- `--jinja` is **enabled by default** — do not add it.
- `--flash-attn` needs an explicit value: `--flash-attn on`.
- Qwen 3.6 works out of the box; the "build from source for Qwen3.6 rope" advice does not
  apply.
- `--mlock` / `--no-mmap` / `--direct-io` are **deprecated** in favour of
  `-lm, --load-mode {none,mmap,mlock,mmap+mlock,dio}`.
- Available and used: `--cache-reuse`, `--batch-size`/`--ubatch-size`, `--cache-type-k/v`,
  `--n-cpu-moe`, `-ot/--override-tensor`, `--threads`/`--cpu-range`/`--cpu-strict`,
  `--reasoning`, `--pooling`, `--embedding`.
- **Log format changed at b10257**: it now emits `srv llama_server: model loaded` instead
  of the classic `llm_load_tensors` / `buffer size` / `KV self` lines. Greps for the old
  strings make a healthy server look hung.

## Hermes wiring (`~/.hermes/config.yaml`)

Shared between both machines; names only aliases.

- `model.default: local-main`, `delegation.model: local-main`.
- `custom_providers[0].models.*.context_length` pinned to **65536** for every alias.
  Without it Hermes reads `*.context_length` from GGUF metadata and advertises the native
  window (256K), overrunning the actual `--ctx-size` KV allocation. Values are the
  **minimum across both machines**. When changing a model's `--ctx-size`, update this too.
- `auxiliary.<task>.{provider,model,base_url,api_key,timeout}` — `base_url` set explicitly
  on every one so they cannot silently fall back to openrouter.

Auxiliary tasks split on **critical path vs background**, not prompt size:

| tier | tasks |
|---|---|
| `local-main` | `compression`, `mcp`, `skills_hub`, `triage_specifier`, `kanban_decomposer`, `goal_judge` |
| `local-vision` | `vision` |
| `local-tiny` | `title_generation`, `curator`, `profile_describer`, `monitor`, `tts_audio_tags`, `web_extract`, `approval`, `memory_query_rewrite` |

Anything the user waits on goes to `local-main` — it is faster *and* reuses the loaded
model. Fire-and-forget goes to the iGPU so it does **not** evict the large model.
Timeouts are well above Hermes' defaults because a timeout mid-compression drops context.

**Delegation runs on `local-main`, measured not assumed:** 33.6s vs 2m05.8s on the iGPU.
During synchronous delegation the parent is idle so the primary GPU is free anyway and the
child reuses the loaded model; each instance is `--parallel 1` so concurrent children
serialize either way; and subagent cost is prefill-dominated, where the iGPU is weakest.
The iGPU only wins for `background=true` delegation.

**`approval` MUST stay on a non-thinking model — correctness, not preference.**
`tools/approval.py::_smart_approve` sends `max_tokens=16, temperature=0` and expects one
word. On a thinking model the whole budget goes to reasoning:

| tier | result |
|---|---|
| `local-main` (thinking on) | `finish=length`, 64 chars reasoning, **content `''`** |
| `local-tiny` (`--reasoning off`) | `finish=stop`, 0 reasoning, **`APPROVE`** |

Smart approval was silently broken while it pointed at `local-main`. Do not move it back
without raising `max_tokens` in upstream code. Caveat: `_smart_approve` would not fire from
a `hermes -z` one-shot even with a flagged command — verify interactively, watching
`podman logs llama_swap_intel | grep -c "POST /v1/chat/completions"`.

**`memory_query_rewrite` almost certainly never fires** — only external memory providers
reference it, and `memory.provider` is empty.

**`auxiliary.web_extract` is misleadingly named.** It does not control the `web_extract`
tool (`tools/web_tools.py` makes no LLM call — it truncates at 15000 chars). It is consumed
by `tools/browser_tool.py` for browser *snapshots*, gated on
`len(snapshot_text) > 15000 and user_task`. In three realistic attempts it never fired
once. Verify with request counts before concluding a change to it did anything.

**Hermes cannot consume `local-embed`** — no embedding config key exists and nothing calls
`/embeddings`. It is for the qdrant/n8n stack, `research.yml`, or direct API use.

## LiteLLM

- **Takes ~30-60s to become ready** after `up`/`restart`. Requests before then return an
  empty body that looks like a model failure. Poll `/health/liveliness`.
- **`request_timeout: 600`** — local inference trips the default; a cold load plus vision
  prefill surfaced as a useless `InternalServerError - Connection error`. Don't lower it.
- **Fallbacks match the name as *requested*, not resolved.** `local-vision` does not
  inherit a fallback declared for `qwen3.6-35b` — it fails with `No fallback model group
  found for original model_group=local-vision`. Every alias needs its own entry.
- **Do not list one machine's models in the other's config.** The laptop once carried the
  desktop's entries pointing at an unreachable host; once the laptop gained its own
  `gemma-4-26b` that became a duplicate `model_name` and LiteLLM would have load-balanced
  across a live and a dead endpoint.

## Operational gotchas

- **Editing a bind-mounted file replaces its inode**, so the container keeps serving the
  old one. `podman-compose up -d` is a no-op (nothing in the compose file changed) and
  llama-swap's own 2s config poll watches the stale inode. **`podman restart
  llama_swap_nvidia` is the fix** after any config edit.
- **`localhost` resolves to `::1` first.** llama-server binds IPv4 `0.0.0.0`, so podman's
  IPv6 forward accepts then resets — `Connection reset by peer`, which reads as a dead
  process. Use `127.0.0.1`. This also makes containers report `(unhealthy)` spuriously.
- **Thinking models return empty `content` on small budgets.** `qwen3.5-9b` asked to "reply
  with just OK" spent 176 tokens reasoning first, and returned empty at `max_tokens: 16`.
  Give local models 400+, and 1200+ if the test must see an answer.
- **Only one dGPU model is resident.** `groups: swap: false` keeps multiple resident on the
  iGPU but the 8GB card cannot co-locate the large models — switching is an inherent
  ~15-30s swap.
- **Deliberately not used:** `--mlock` (fights llama-swap's TTL load/unload).

## Testing

From the [llm-benchmarking](https://github.com/amidg/llm-benchmarking) repo, with
`LITELLM_ENV` pointing at `ai/litellm.env`:

```bash
./smoke.py                                       # every tier + alias; non-zero on failure
./llmbench.py --models a b --tests all           # compare models
./llmbench.py --models local-main --fail-on-regression
```

`smoke.py` replays the exact `max_tokens=16` approval shape and flags empty-content
responses — that is how the smart-approval breakage was found. `llmbench.py` interleaves
models across rounds so thermal drift is shared rather than stacked.

**Benchmark methodology rules learned the hard way:**

- **Give tests a thinking-model-sized budget.** `t_tools` and `t_quality` once ran at
  400/300 tokens; a model that spent the whole budget reasoning scored identically to one
  that answered wrong. A **3/4 where a different case fails each run is a budget problem,
  not a defect.** Both now budget 1200 and report `empty` separately.
- **Repeated identical prompts hit the prompt cache.** A single-model loop shows `ptok=4`
  on rounds 2+ and a meaningless prefill number. `llmbench.py` avoids this by alternating
  models, which flushes the cache — only round 1 is valid otherwise.
- **Vision must be tested with a real image** — see the vision floor above.

```bash
curl -s 127.0.0.1:8081/v1/models | jq '[.data[]|{id,status:.status.value}]'
podman logs --tail 20 llama_swap_nvidia
nvidia-smi --query-gpu=memory.used,memory.total --format=csv
free -h                                          # iGPU "VRAM" is host RAM
curl -s -X POST 127.0.0.1:8081/api/models/unload  # free the GPU between runs
```
