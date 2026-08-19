# AGENTS.md — local LLM stack

Everything non-obvious about this stack lives here. Read before editing any config.

## Document structure — where things belong

| file | contains | audience |
|---|---|---|
| `README.md` | how to run it, endpoints, aliases, a handful of headline numbers | humans |
| `AGENTS.md` | **all rules, rationale and accumulated learnings** | agents + whoever edits configs |
| `*.yml`, `*.yaml` | **working config only — no comments** | the runtime |

**The benchmark harness is not in this repo.** It lives in
[amidg/llm-benchmarking](https://github.com/amidg/llm-benchmarking) — see
[Benchmarking](#benchmarking) below before measuring anything.

**Configs carry no comments by design.** Rationale rots when it sits next to the flag it
explains; it gets copied, contradicted, and never re-measured. If a setting needs
justifying, justify it here with the measurement that produced it. If you change a tuned
value, update the table here in the same commit.

## Architecture

Two machines. Each llama-swap instance mounts one config and advertises only what its
device can run.

| config | container | device | port | models |
|---|---|---|---|---|
| `llama-swap-nvidia.yaml` | `llama_swap_nvidia` | RTX 5070 8GB (laptop) | 8081 | `qwen3.6-35b` (default, MTP, 128K), `gemma-4-26b` (MTP, vision, 128K) |
| `llama-swap-intel.yaml` | `llama_swap_intel` | Arc Pro iGPU (laptop) | 8082 | `gemma-4-e2b` (**local-tiny + local-vision**), `qwen3.5-2b` (`local-tiny` fallback) |
| `llama-swap-server.yml` | `llama_swap_server` | 7900 XTX 24GB (desktop) | 8080 | `qwen3.8-27b` (**medium default**, MTP, 128K, Vulkan), `qwen3.8-27b-xhigh` / `qwen3.8-27b-low` (same config, that effort), `qwen3.6-35b` (**MTP + vision**, 128K, Vulkan) |

### Qwen3.8-27B on 7900 XTX 24GB — promoted config (2026-08-15)

MTP 128K, Vulkan backend on AMD RDNA3. Quant: IQ4_XS. KV quant: `q5_0`/`q4_1`. Harness
uses `chat_template_kwargs: {"reasoning_effort": "low"}`. Reasoning efforts can be set per
request and should be embedded into the agentic harnesses. Available levels are:
- xhigh (default): for complex tasks demanding thorough analysis
- medium: balancing accuracy and speed
- low: efficient reasoning optimizing for speed and cost
- none

**Decision: three llama-swap siblings — `qwen3.8-27b` (medium default), `qwen3.8-27b-xhigh`, and
`qwen3.8-27b-low` (identical config, only the baked `reasoning_effort` differs; 2026-08-18).** Per-request `reasoning_effort` does not survive the
gateway (`drop_params: true` drops it silently — see *Reasoning stays off* in the tiny-tier
section), so the effort is embedded per instance via `--chat-template-kwargs`; a direct
per-request `chat_template_kwargs` still overrides the baked default. One 24GB card cannot
co-locate two ~16GB instances, so the old `groups: swap: false` pin was removed — pinned
members are never evicted, which would have made the second instance unloadable (OOM). Both
entries are `ttl: 0`: no idle unload, each stays resident until VRAM pressure forces a swap
to the other variant (cost: one cold load, ~the usual swap time). A `qwen3.6-35b` (MTP + vision, `--n-cpu-moe 15`) entry joined this same box on 2026-08-18; with three ~16GB Qwen plus a 22.66GB MoE sharing one 24GB card, at most one model is resident at a time, so any cross-model switch costs a full cold load.

| model | prefill | decode | deep | acc s/d | tools | quality |
|---|---|---|---|---|---|---|
| **qwen3.8-27b** (q5_0/q4_1, ub2048) | **743 t/s** | **52.0 t/s** | **63.9 t/s** | 51%/82% | 4/4 | 4/4 |
| qwen3.8-27b (q5_0/q4_1, ub1024) | 731 t/s | 52.2 t/s | 62.8 t/s | 52%/80% | 4/4 | 4/4 |
| qwen3.8-27b (q4_0/q4_0, ub1024) | 735 t/s | 52.3 t/s | 60.4 t/s | 51%/73% | 4/4 | 4/4 |
| qwen3.8-27b (q4_0/q4_0, ub512) | 721 t/s | 51.0 t/s | 61.4 t/s | 48%/76% | 4/4 | 4/4 |

**Decision: q5_0/q4_1 KV at ubatch 2048 as default.** Highest deep decode (63.9 t/s),
highest acceptance at depth (82%), identical correctness to all variants. Longctx 50K at
526 t/s / 95.1s (within noise of q4/q4).

**Decision: Vulkan backend for AMD RDNA3.** Benchmarked ROCm vs Vulkan on identical
hardware (7900 XTX). ROCm wins prefill by ~16% (856 → 735 t/s) and longctx by ~12%, but
Vulkan beats ROCm on deep decode (63.9 vs 61.7 t/s at ub512, 60.4 at ub1024), on
acceptance at depth (82% vs 76-78%), and avoids the GTT fallback that killed `q8_0`/`q8_0`
and `q4-ub2048` on ROCm. Deep decode is what an agent turn does — Vulkan is the right
choice. ROCm ub512 remains the best ROCm config (no GTT fallback, stable) but Vulkan wins
on the metric that matters for agentic workloads.

**Decision: q8_0/q8_0 KV rejected.** Best deep at 65.8 t/s, highest acceptance at 86%,
but prefill collapses to 23 t/s on rounds 2-3 (model reload between rounds). Likely a
llama-server bug with q8_0 cache persistence across restarts. All correctness passes
but the instability disqualifies it.

**Thinking:** ON (368-482 reasoning chars). Approval FAIL at max_tokens=16 — reasoning
consumes the budget. Harness workaround: `chat_template_kwargs: {"reasoning_effort": "low"}`
reduces reasoning to ~83 chars for tool/quality tests.

**Qwen 3.8 27B Settings**: Use the following link: https://unsloth.ai/docs/models/qwen3.8#qwen3.8-27b-settings. By default use thinking mode settings

**Harness fixes (2026-08-15):** `parallel.py` read `completion_tokens` from `timings` but
llama.cpp puts it in `usage`. Fixed `timings()` to merge `usage` fields. Replaced
anti-thinking system messages with `chat_template_kwargs` for `reasoning_effort: "low"`.

Host ports: **8081 primary GPU, 8082 secondary, 8083 NPU** on the laptop; the desktop's
llama-swap is on **8080** and Open WebUI on **3000**. Both machines run
`container_name: litellm` on 4000 — they are separate hosts, so there is no conflict.

Container-internal ports are always 8080, which is why `litellm-config.*.yaml` points at
`http://llama_swap_*:8080/v1` regardless of the host mapping. Changing a host port does
not require a LiteLLM change.

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
| `local-main` | `server-qwen38-27b` (remote, medium) | `qwen3.8-27b` | main agent, delegation, anything user-facing |
| `local-vision` | `server-qwen38-27b` (remote) | **same as laptop** | images/PDFs — **projector model only** |
| `local-tiny` | `gemma-4-e2b` (iGPU) | `gemma-4-12b` | background/fire-and-forget; **same model as `local-vision`, so no swap between them** |
| `local-embed` | **unwired** | **missing** | RAG embeddings, 1024-dim |

`gemma-4-26b` has no alias; requesting it evicts the loaded model (~15-30s) since only one
fits in 8GB. **Both dGPU models now run 128K**, so there is no separate big-context entry.

- **`local-embed` is currently unwired on BOTH machines.** `llama-swap-intel.yaml` no longer
  defines an `embed` model and there is no alias, though `Qwen3-Embedding-0.6B-Q8_0.gguf` is
  still on disk. Anything calling `/v1/embeddings` (qdrant/n8n, `research.yml`) fails today.
  Do not "fix" it by pointing the alias at a chat model — a chat deployment cannot serve
  `/v1/embeddings`.
- **There is deliberately no `local-support`.** It existed, resolved to the same iGPU
  model as `local-tiny`, and had no consumer. Two names for one thing drift apart.
- **`local-vision` must never fall back to a model without a projector.** A blind model
  confidently describing an image is worse than a clean error. Since 2026-08-17 the laptop
  alias resolves to the remote `server-qwen38-27b` (projector) and its **only** fallback is
  `gemma-4-e2b` (iGPU, resident, projector, `--reasoning off`) — operator decision; before
  that the fallback was dGPU `gemma-4-26b`, and before that `gemma-4-e4b` until it was
  removed (2026-08-06). When deleting a vision model, **re-point this fallback in the same
  change**, or the invariant breaks silently and only shows up on an image request.
- **Vision left the dGPU on 2026-08-06.** `local-vision` now resolves to `gemma-4-e2b` on
  the Arc iGPU. The dGPU tier runs `--no-mmproj`, which is what freed the headroom MTP and
  `ubatch 2048` need — at `--n-cpu-moe 31` **the MTP model OOMs outright** with a projector
  loaded. The dGPU now correctly *rejects* images rather than crashing on them, so the
  "vision floor" below is no longer a live constraint on this tier. Since 2026-08-17 it
  resolves to the remote `server-qwen38-27b` instead (see the invariant above) — the iGPU
  model remains its fallback.

## Measured performance (laptop)

Absolute values drift 20-30% with load and thermals — **only compare models measured in
the same session.** Ratios have been stable across every repetition.

| device | model | prefill | decode (deep) | VRAM |
|---|---|---|---|---|
| RTX 5070 | `qwen3.6-35b` **(default, MTP, 128K)** | **991 t/s** | **46.3 t/s** (41.2 shallow), 36.9 @118K | ~7275 MiB |
| RTX 5070 | *no-MTP control* **(arm removed)** | 410 t/s | 29.7 t/s (35.3 shallow) | ~6100 MiB |
| RTX 5070 | `gemma-4-26b` *(MTP, vision, 128K)* | 1267 t/s | 26.3 t/s (25.3 shallow) | ~7105 MiB |
| Arc iGPU | `gemma-4-e2b` **(local-tiny + local-vision)** | **713 t/s** | **14.4 t/s** (17.4 shallow) | ~3.5 GB RAM |
| Arc iGPU | `qwen3.5-2b` | 558 t/s | 23.1 t/s *(stale, pre-2026-08-06)* | 1.34 GB RAM |
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
| `qwen3.6-35b` | 40 | 256 / 8 active | **MTP-**UD-Q4_K_M (22.66 GB) | **35** |
| `gemma-4-26b` | 30 | 128 / 8 active | UD-Q4_K_M (16.9 GB) + MTP head | **30** |

### N is nearly free WITHOUT MTP and expensive WITH it — do not confuse the two

**Without MTP** (`--ubatch-size 512`, mmap, `--threads 6`, everything else fixed):

| N | mmproj | prefill | shallow | **deep** | VRAM |
|---|---|---|---|---|---|
| **34** | yes | 454 t/s | 37.2 | **31.4** | 6947 MiB |
| 33 | yes | 461 t/s | 37.3 | **31.8** | ~7452 MiB |
| 31 | no | 483 t/s | 38.8 | **31.7** | ~6100 MiB |

Three expert layers moved deep decode by 0.3 t/s — noise. That produced the old rule,
*"N does not buy deep decode, tune it for VRAM headroom."*

**With MTP that rule is wrong, by roughly 10x** (2026-08-06, promoted config, ctx held at
64K so only N varies):

| N | prefill | shallow | **deep** |
|---|---|---|---|
| **34** | 1329 t/s | 43.3 | **47.6** |
| 38 | 1278 t/s | 39.3 | **44.3** |

**Four layers cost 3.3 t/s (-7%)**, where three used to cost 0.3. The likely mechanism:
MTP verifies 2-3 tokens per step, so each step does several times the expert-gather work
of a batch-1 decode — which makes *where the experts live* matter far more than it did.

**Consequence: do not nudge N upward for headroom on an MTP config.** Buy headroom by
dropping `--ubatch-size` first (2048 → 1024 costs prefill, which has 3x of margin, instead
of decode, which has none). N=34 is the promoted value and should stay unless a load
actually fails.

### 128K is the default, bought with `ubatch` not `N` (2026-08-06)

**`--ctx-size 131072`, `--n-cpu-moe 35`, `--ubatch-size 1024`.** The separate
`qwen3.6-35b-128k` entry is gone — one model, one window.

This came from an OpenCode failure: `request (72027 tokens) exceeds the available context
size (65536)` at session step 12. **The suspected cause — `AGENTS.md` being too big — was
wrong.** This file is ~12-14K tokens, under 20% of a 64K window. The 72K was system prompt +
tool schemas + this file + file reads + twelve turns of history.

The route to a bigger window is the thing worth remembering:

| ctx | N | ubatch | prefill | **deep** | accept @depth | free VRAM |
|---|---|---|---|---|---|---|
| 64K | 34 | 2048 | 1322 t/s | 47.1 | 77% | 442 MiB |
| 96K | 34 | 2048 | — | — | — | **OOM** |
| 96K | 35 | 2048 | 1316 t/s | 46.0 | 77% | 390 MiB |
| **96K** | **34** | **1024** | 1004 t/s | **48.1** | **80%** | 408 MiB |
| 128K | 34 | 1024 | — | — | — | **OOM** |
| 128K | 34 | 512 | — | — | — | 294 MiB (surrenders 3x prefill) |
| **128K (promoted)** | **35** | **1024** | **989 t/s** | **46.8** | 78% | 468 MiB |
| 128K | 36 | 1024 | 975 t/s | 43.5 | 71% | 932 MiB |

**This confirms the ubatch-before-N rule empirically for the first time.** At 96K the two
routes were measured head to head: `ubatch 2048 → 1024` cost **zero decode** (48.1 vs 47.1)
while `N 34 → 35` cost 2.3%. The rule was previously inferred from an N-sweep; it now has a
direct comparison behind it.

**N=36 is far worse than the linear model predicts.** Two layers past 35 cost 3.3 t/s, not
the ~1.6 the earlier sweep implied, and draft acceptance drops 78% → 71%. Do not assume the
N penalty is linear.

Validated at full size, not just at load: **118,018-token prompt, needle found, 406 MiB
still free**, TTFT 157s, decode 36.9 t/s at depth. `tools` 4/4, `quality` 4/4.

**`gemma-4-26b` needed the same treatment and it was not optional.** At 128K/N=30/ub2048 it
loaded with **22 MiB free** — unusable, and exactly the shape that has crashed this stack
twice. Dropping to `ubatch 1024` took it to **642 MiB**, and it survives a 1280px image at
588 MiB.

**Cost of the window: prefill 1322 → 989 t/s (-25%).** Decode is unchanged-to-better. That
is the right side of the trade for this stack — a window that truncates is a correctness
problem, a slower prefill is a comfort problem.

### `qwen3.6-35b` is a hybrid, so context is cheap

`full_attention_interval: 4` — only **10 of 40 layers** carry a KV cache; the rest are
SSM/Mamba blocks with constant state. KV at 64K with `q4_0` is ~360 MiB. Halving
`--ctx-size` frees under 200 MiB, so **context reduction is not a VRAM lever here.**

### `-ctk q8_0` is a legitimate hypothesis but is NOT free — analysed, not run (2026-08-09)

The claim doing the rounds: `q4_0` K at long context corrupts tool-call JSON and
hallucinates file paths, K being more sensitivity-critical than V, so run `-ctk q8_0 -ctv
q4_0`. Worth testing — **but it is usually pitched as cheap, and on this box it is not.**

Arithmetic from the row above: KV at 64K/`q4_0` ≈ 360 MiB → 128K ≈ 720 MiB, of which K is
~360 MiB. Promoting K to `q8_0` roughly doubles that half: **~+360 MiB against the 468 MiB
free** in the promoted 128K config. This stack has crashed twice at ~22 MiB free. So it has
to be bought — `--ubatch-size 1024 → 512` (surrenders 3x prefill) or a smaller window
(frees only ~180 MiB, per the hybrid note above). **It is nearly free in a no-MTP parallel
variant**, which returns ~1.1 GB — see
[Parallel subagents](#parallel-subagents--analysed-not-measured-2026-08-09).

Gate it on `llmbench.py --tests tools quality` and retry counts, **not on t/s** — the whole
claim is about correctness. Same 30-step agent task both ways, count retries.

### Prompt cache on a hybrid model — `-cram`/`-ctxcp` are suspect (2026-08-09)

Upstream issue **#24055**, *"Context checkpoints always invalidated on hybrid/recurrent
models"*: the server logs `forcing full prompt re-processing due to lack of cache data
(likely due to SWA or hybrid/recurrent memory)` and **`--cache-reuse`, `--ctx-checkpoints`
and `--cache-ram` are all rendered ineffective.** Introduced at commit `e98cb51`, **still
open**. `qwen3.6-35b` is exactly the affected shape.

**Do not conclude prompt caching is broken here — it is not.** Live `/slots` on this build,
2026-08-09, mid-request: `n_prompt_tokens: 48360`, `n_prompt_tokens_cache: **42839**`. The
**in-slot contiguous prefix** path works fine. It is **checkpoint restore** (resuming from
the middle of a diverged context) and **idle-slot save** that are suspect. Keep the two
apart when reading any future measurement.

**`-cram 32768` does not fit this box.** The suggestion to crank `--cache-ram` because
"you have 64GB" ignores where the RAM already went:

| | measured 2026-08-09 |
|---|---|
| llama-server RSS (`--load-mode none`, no mmap) | **19.4 GB** |
| stated ceiling for llama-server | 30 GB |
| system | 48/62 GB used, **swap 7/7 GB consumed** |

Ceiling for `-cram` is therefore ~**10240**, not 32768. And it is likely unnecessary at any
size: a full 128K slot state at `q4_0` is ~720 MiB, so the **8192 default already holds ~11
of them**. `--cache-idle-slots` additionally *requires unified KV*, so it is downstream of
the parallel-slots decision entirely.

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

### `--ubatch-size 2048` triples prefill on the dGPU (2026-08-06)

The dGPU ran `--batch-size 1024 --ubatch-size 512` for months. It was **inherited, never
swept** — the documented ubatch sweep further down was on the *Arc iGPU*, where 1024 won
and 2048 regressed. **That result does not transfer to the dGPU:**

| ubatch (dGPU, MTP, N=34) | prefill | deep |
|---|---|---|
| 512 | 334-431 t/s | 44.9 |
| **2048** | **1011-1324 t/s** | 46.4-46.9 |

~3x prefill for no decode cost. At 50K context the needle prefill dropped **122.9s → 41.7s**.
Cost is VRAM: the compute buffer grows, leaving **442 MiB free** at N=34 (vs ~1040 at
ubatch 512). Stable through a full 50K run, but there is no room left for a vision
projector — which is fine only because vision moved to the iGPU. **Drop to `ubatch 1024`
before raising `--n-cpu-moe` if headroom is ever needed** — with MTP, N is the expensive
lever and prefill is the one with margin.

`gemma-4-26b` was later measured properly (see below) and the propagated flags held up:
**616 → 1621 t/s prefill, 17.9 → 24.9 t/s deep.** The propagation guess was right, but it
was a guess until measured.

### `--load-mode none` beats mmap when experts are CPU-resident

llama.cpp emits this on every load with `--n-cpu-moe`: *"tensor overrides to CPU are used
with mmap enabled - consider using --no-mmap for better performance."* It is right.

| load mode | prefill | deep |
|---|---|---|
| mmap (default) | 334 t/s | 44.9 |
| **`--load-mode none`** | **667 t/s** | **48.6** |

**This is not about memory pressure** — see the negative result below. It is mmap
indirection on the expert-gather path, which decode hits on every token.

The obvious objection — that reading 22.6 GB upfront lengthens every llama-swap TTL
reload — **was measured and does not hold: cold load + first response is 18.7s**, inside
the 15-30s swap the tier already pays. `--mlock` remains rejected (it fights TTL); `none`
does not, because it does not pin.

### Gemma 4 MTP — works on b10257+, and it *frees* VRAM (2026-08-06)

**`gemma4-assistant` loads fine on b10276.** Community reports that Gemma-4 MTP needs
am17an's branch do not apply to this image.

**Gemma's MTP head is a SEPARATE file, unlike Qwen3.6's.** Unsloth's wording ("an
additional MTP file inside a separate folder within the GGUF package") means the *repo* has
an `MTP/` folder — the GGUF itself does not bundle it. Verified by parsing both Gemma GGUFs'
tensor tables: 658 tensors each, **zero** MTP/draft/assistant tensors. So Gemma needs
`--model-draft`; Qwen3.6 must not have it.

`mtp-gemma-4-26B-A4B-it-Q8_0.gguf` (462 MB) is `gemma4-assistant`, 4 blocks,
`embedding_length_out = 2816` — which **must match the target's `n_embd`**, same rule as
projectors. Check it before assuming a head fits a model.

| config | N | prefill | **deep** | accept s/d | free after 1280px image |
|---|---|---|---|---|---|
| Q4_K_M, no MTP | 26 | 1721 t/s | 22.8 | — | 412 MiB |
| Q4_K_M + MTP | 28 | 1660 t/s | **26.1** | 65%/75% | **104 MiB** — too thin |
| **Q4_K_M + MTP (promoted)** | **30** | 1621 t/s | **24.9** | 60%/75% | **1172 MiB** |

**MTP nets VRAM here rather than costing it** — the opposite of Qwen, where it had to be
paid for by dropping vision. Offloading N=26→30 frees ~1.7 GB while the head consumes only
462 MB, so the promoted config is **both faster and safer** than the non-MTP one it replaced.
N=28 is faster still (26.1) but leaves 104 MiB after a real image, which is inside the crash
zone for a model that exists to be a *fallback*.

**The built-in vision test cannot catch this.** `llmbench`'s `t_vision` sends a **1x1 PNG**,
which barely allocates an encoder buffer — it passed at 104 MiB free. The margin only became
visible with generated 768px and 1280px images. Treat a `vision: yes` from the harness as
"the projector is wired up", not "vision is safe at this headroom".

### Quant: Q4_K_M over Q4_K_XL again (2026-08-06)

Same flags, 3 rounds, both without MTP:

| quant | prefill | deep | tools | quality |
|---|---|---|---|---|
| **UD-Q4_K_M** | 1722 t/s | 22.8 | 4/4 | **4/4** |
| UD-Q4_K_XL | 1718 t/s | 22.8 | 4/4 | **3/4** |

**Speed is a dead heat**, so quality decided it: Q4_K_XL reasoned 4296 chars on
`terse_title` and hit the cap with empty content; Q4_K_M answered cleanly. Same direction as
the Qwen result (Q4_K_M 31.4 vs Q4_K_XL 30.4). Caveat: that is *one* prompt — the
speed tie is what makes it a free choice, not the strength of the quality evidence.

**Known quirk:** Gemma wraps `extract_json` output in ``` fences where Qwen returns bare
JSON. It passes the substring check, but a caller doing `json.loads()` on raw content will
break. Same behaviour noted for `gemma-4-e2b` in the tiny tier.

### Page-cache eviction is NOT a bottleneck here — do not re-investigate

zram swap sits at 8G of 8G and ~20 GB of experts live in page cache, which looks alarming
and is not. Sampled through sustained decode: `maj_flt` **7902 → 7904 over a minute**
(2 faults), `VmSwap=0` throughout, `vmstat so=0`. RSS climbing 10.7 → 16.3 GiB is mmap
warm-up, not thrash. The full zram is stale allocation, not live pressure.

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
per batch. *(That IQ4_XS row is **superseded** — measured pre-`deep`, pre-thread-tuning,
pre-MTP. It is not comparable to anything current and was not re-run, because a non-MTP
config can no longer be promoted.)*

### Q4_K_M is the floor — smaller K-quants lose too (2026-08-06)

`UD-Q3_K_XL` is 24% fewer expert bytes than `UD-Q4_K_M` and a K-quant, so it isolates the
question IQ4_XS confounded: *does a smaller expert footprint buy decode when dequant cost
is held cheap?* Both MTP builds, every other flag identical, same session:

| quant | prefill | shallow | **deep** | accept s/d | tools | quality |
|---|---|---|---|---|---|---|
| **MTP-UD-Q4_K_M** | 1331 t/s | 42.0 | **47.6** | 60%/77% | 4/4 | 4/4 |
| MTP-UD-Q3_K_XL | 1477 t/s | 37.8 | **43.3** | 58%/78% | 4/4 | 4/4 |

**Answer: no. Q3_K_XL is 9% slower on deep decode despite reading 24% fewer bytes.**

Acceptance is identical (58%/78% vs 60%/77%), which **rules out the obvious explanation** —
Q3's weaker weights do *not* produce a worse draft head. The cost is dequantisation: Q3_K's
3-bit packing takes more CPU work per weight to unpack than Q4_K, and on this AVX2-only CPU
that outweighs the bytes saved. Prefill moves the other way (+11%) because prefill is
GPU-bound.

**Two independent quant families now lose the same way** (IQ4_XS, Q3_K_XL). The rule for
this hardware: **Q4_K_M is the floor. Going smaller costs more in dequant than it saves in
bytes.** Do not re-test this a third time without a new reason — e.g. a llama.cpp release
with reworked Q3_K/i-quant CPU kernels, or a CPU with AVX-512/AMX.

At 128K, Q4_K_M also stays ahead (36.4 vs 33.7 deep), so Q3_K_XL wins on no axis. Both
Q3_K_XL files (~34 GB) can be deleted.

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

## MTP — the single biggest win on this tier (2026-08-06)

**MTP is supported and is now the default.** The old note here ("no MTP support, no `--mtp`
flag") was true when written and is wrong now: llama.cpp merged MTP in PR #22673 and
b10276 exposes `--spec-type draft-mtp`. For Qwen3.6 the MTP head ships **inside the same
GGUF** (`MTP-UD-Q4_K_M` is 22.66 GB vs 22.13 GB plain, a ~505 MiB head), so **no
`--model-draft` is needed** — that flag is only for Gemma-style separate heads.

Measured against the no-MTP control (same file, no `--spec-type`), same session, 3 rounds:

| context | control deep | MTP deep | gain |
|---|---|---|---|
| ~6.5K | 29.7-31.2 | **46.9** | **1.53x** |
| ~58K | 15.6 | **40.4** | **2.59x** |

**The gain grows with context, and deep decode exceeds shallow** (47.6 deep vs 42.8
shallow) — the reverse of the control's normal 35.3 → 29.7 decay.

**The mechanism is measured, not assumed: draft acceptance rises with context.**
`llmbench` reports it per depth (`acc s/d`), and it is stable across quants and runs:

| depth | acceptance |
|---|---|
| shallow (~0 ctx) | **56-65%** |
| deep (~6.5K ctx) | **77-78%** |

An established context makes continuations more predictable, so more drafted tokens
survive verification. MTP is therefore strongest exactly where this stack was weakest.
*(An earlier revision of this file cited "80.1%" as evidence for this — that was a single
sample from a 27-token prompt, i.e. the shallow case, and could not support a claim about
depth. The conclusion held; the evidence did not.)*

### Why the published MoE numbers understate this machine badly

Community MoE figures are 1.17x (RTX PRO 6000) to 1.40x (Strix Halo) because a
fully-GPU-resident A3B reads ~3 GB of experts per token and is already at its
memory-bandwidth ceiling — no slack for MTP to exploit. **That does not describe this
box.** With `--n-cpu-moe 34` the same CPU-resident experts sustain ~450 t/s in prefill and
~31 t/s in batch-1 decode — a 14x gap. The CPU expert path is **not** read-bandwidth
saturated at batch 1; it is latency/sync-bound (the thread sweep below reaches the same
conclusion independently). Batch-2 verification therefore costs almost nothing extra, and
MTP collects the difference.

**The predicted prefill disaster did not happen.** The PR reports prompt processing at
0.51x from D2H embedding transfers, which on paper made MTP a net loss for prefill-heavy
agent turns. Measured here: **413 → 403 t/s, within session noise.** The D2H cost is
roughly fixed per batch; the PR measured it against a 1315 t/s baseline where it dominated.
Against a 413 t/s baseline already gated by the CPU expert gather, it disappears. **A
published regression measured in a different bottleneck regime does not transfer.**

### `--spec-draft-n-max 3` is not lossless on this build — use 2

MTP should be mathematically lossless. At `n-max 2` it is: `quality` 4/4 with
byte-identical answers to the control. At `n-max 3` it **reproducibly** drives
`terse_title` into a 4172-char reasoning loop and returns empty (`finish: length`), scoring
3/4 — identical `reasoning_chars` across three runs, so deterministic, not sampling noise.
Isolated cleanly: `ubatch 2048` and `--load-mode none` both score 4/4; only `n-max 3` fails.

This corroborates upstream issue #23230, where `n-max 3` regressed 10-15% on recent builds
while `n-max 2` lost ~5%. Two unrelated symptoms on the same parameter: **treat `n-max 3`
as suspect on b10276.** It bought ~2 t/s, which the other levers supply anyway.

MTP forces `--parallel 1` (already the case) — see
[Parallel subagents](#parallel-subagents--analysed-not-measured-2026-08-09) for what that
costs. Re-check `n-max 3` after a llama.cpp upgrade.

## Parallel subagents — analysed, not measured (2026-08-09)

**Nothing in this section was benchmarked.** It exists so the question can be picked up
later without re-deriving it. Every t/s figure here is *cited from tables above*, not
re-measured. Treat the conclusion as a designed experiment, not a result.

The motivating want: Hermes runs subagents, `~/.hermes/config.yaml` sets
`delegation.max_concurrent_children: 3`, so `--parallel 3` looks obviously right.

### It is blocked: MTP and multi-slot are mutually exclusive

`--spec-type draft-mtp` **hard-errors** on multi-slot —
`MTP currently supports only n_parallel=1; got 4` (llama.cpp PR #22673). llama-swap
surfaces this as `upstream command exited prematurely`, which reads like an OOM and is not.

The maintainer on the same PR: *batching with MTP enabled using a recurrent model (i.e.
Qwen3.x) is currently not optimized, so you won't benefit from parallel processing on a
single machine in that case.* **So the non-MTP multi-slot path is unproven on this
architecture too** — dropping MTP is necessary but may not be sufficient.

### What is actually being traded

| | MTP + `--parallel 1` (current) | no-MTP + `--parallel 3 --kv-unified` |
|---|---|---|
| deep decode @6.5K | **46.8-47.6 t/s** | ~29.7-31.2 t/s |
| deep decode @58K | **40.4 t/s** | ~15.6 t/s |
| concurrency | 1 — children serialize | 3 |
| VRAM | 7275 MiB | ~6100 MiB (**~1.1 GB freed**) |

A 3-child fan-out costs `3 × T` serially; in parallel each child runs at ~0.4-0.6x but all
three overlap. **Whether that nets out is empirical and nothing here answers it.** Note the
loss is worst exactly where agent turns live — deep context — because that is where MTP's
draft acceptance is highest (77-78%).

### Two constraints any future attempt must respect

1. **`--ctx-size` is split across slots unless `-kvu` is set.** `131072` with `--parallel 3`
   and no `--kv-unified` gives ~43K per slot, and Hermes pins `local-main` at `131072`
   (see [Hermes wiring](#hermes-wiring-hermesconfigyaml)) — it would overrun immediately.
   **`--kv-unified` is mandatory in the parallel variant, not optional.** The default is
   *"enabled if number of slots is auto"*, so setting `--parallel N` explicitly silently
   turns it off. This trap is real and the suggestion that surfaced it was correct.
2. **Per-sequence recurrent state ×3, cost unknown.** 30 of 40 layers are SSM/GDN blocks
   whose state is allocated per sequence, and this has never been measured on this box. The
   ~1.1 GB freed by dropping MTP is what has to pay for it. **If a parallel variant fails to
   load at 128K, that is the finding** — record it, do not just lower `--ctx-size` and
   move on.

### `--kv-unified` does not buy shared prefixes on this model

Cross-slot prefix adoption (metadata-only `llama_memory_seq_cp`, one slot's cached prefix
adopted by another) is **gated off automatically on hybrid-GDN models**, which `qwen3.6-35b`
is (`full_attention_interval: 4`). Unified KV here gives a shared *pool* the slots draw from
dynamically — genuinely the right shape for bursty subagents — but **not** shared *prefixes*.
Do not budget for the second effect. `-sps/--slot-prompt-similarity` (default 0.10) is
likewise meaningless at one slot and only worth tuning inside a parallel variant.

### The experiment, if it is ever run

`~/Projects/llm-benchmarking/concurrent.py` already does exactly this — `--conc-levels`,
per-level throughput and p99 TTFT, and a `longctx` test that builds a ~15K shared prompt.
Free the GPU first (`curl -s -X POST 127.0.0.1:8081/api/models/unload`), then three
temporary llama-swap entries with `--n-cpu-moe 35 --ubatch-size 1024` pinned so only the
intended variable moves:

| entry | change from today |
|---|---|
| `q35-mtp-serial` | none — the control |
| `q35-par3` | drop `--spec-type draft-mtp --spec-draft-n-max 2`; add `--parallel 3 --kv-unified` |
| `q35-par3-tuned` | `q35-par3` + `-sps 0.5 -cram 10240 --cache-idle-slots` |

```bash
cd ~/Projects/llm-benchmarking
./concurrent.py --models q35-mtp-serial q35-par3 q35-par3-tuned \
  --endpoint http://localhost:8081/v1 \
  --tests longctx tools --conc-levels 1 3 --requests 12 --json ~/bench-par3.json
```

Record per variant: aggregate t/s at conc=3, p99 TTFT, VRAM at load, peak RSS, and whether
it loads at all.

**Decision rule:** a parallel variant wins only if conc=3 wall-clock beats the serial
control **and** single-request deep decode has not made the interactive orchestrator turn
visibly worse. Both conditions, not either.

**Harness caveat — fix before trusting the number.** `concurrent.py::_longctx_prompt()`
sends a **byte-identical** prompt to all concurrent requests, which flatters any
prefix-sharing path. Give each request a distinct suffix first. Same class of trap as
[repeated identical prompts hitting the prompt cache](#reading-its-output-against-this-stack).

### If serial wins

Lower `delegation.max_concurrent_children` to 1 and stop pretending. Routing children to a
second tier is then separate work — and note the *measured* result that delegation on
`local-main` beats the iGPU **33.6s vs 2m05.8s**, because subagent cost is prefill-dominated
and that is where the iGPU is weakest. A second tier is not an obvious win either.

## The tiny tier (Arc iGPU)

**`gemma-4-e2b` serves BOTH `local-tiny` and `local-vision`** — Q4_K_M, 64K, `--ubatch-size
2048`, **`f16` KV**, **no MTP**, `--reasoning off`. It is the only vision model on this tier;
since 2026-08-17 it is also the sole `local-vision` fallback (the alias itself resolves to
the remote `server-qwen38-27b`; before that the fallback was `gemma-4-26b` on the dGPU).

Validated 2026-08-06: **713 t/s prefill, 17.4 shallow, 14.4 deep**, `tools` 4/4,
`quality` 4/4, thinking **off** (0 reasoning chars), **approval PASS**, vision `Red`,
needle found at 53,567 tokens.

### MTP is a LOSS here — the exact inverse of the dGPU (2026-08-06)

MTP is the single biggest win on the dGPU. On the iGPU it **must not be enabled**. Both
Gemma heads load and run correctly on SYCL (`gemma4-assistant` works — that was not
guaranteed; the upstream PR reported garbage output on Vulkan), so this is a performance
verdict, not a compatibility one.

Six arms, one session, 2 rounds, `--ubatch-size` as noted:

| arm | prefill | shallow | **deep** | accept s/d |
|---|---|---|---|---|
| **`gemma-4-e2b` no MTP, ub2048** | **704 t/s** | 17.1 | **14.3** | — |
| `gemma-4-e2b` no MTP, ub1024 | 672 t/s | 16.8 | **14.3** | — |
| `gemma-4-e2b` +MTP, ub2048 | 726 t/s | 18.3 | 12.2 | 37%/41% |
| `gemma-4-e2b` +MTP, ub1024 | 695 t/s | 18.6 | 11.5 | 39%/**29%** |
| `gemma-4-e4b` no MTP, ub1024 | 481 t/s | 11.3 | 10.1 | — |
| `gemma-4-e4b` +MTP, ub1024 | 473 t/s | 13.4 | 9.8 | 39%/38% |
| `gemma-4-e4b` +MTP, ub2048 | 504 t/s | 13.7 | 8.9 | 38%/38% |

**MTP improves shallow and destroys deep.** E2B: shallow 17.8 → 18.6 (+4%), deep 15.3 →
11.5 (**-25%**). `decode` is the number every online benchmark quotes; `deep` is what an
agent turn does. **Judging this on shallow would have shipped a 25% regression.**

**Why it inverts.** The dGPU win comes from CPU-offloaded experts being latency/sync-bound
with ~14x batching headroom, and from acceptance *rising* with context (56-65% → 77-78%).
The iGPU is fully GPU-resident and **bandwidth-bound** — there is no batching slack for
verification to exploit. Acceptance is only ~40%, and on E2B it *falls* with depth
(39% → 29%), the opposite of the dGPU. Verification costs more than drafting saves.

**Same lever, opposite sign, for a reason already in this file.** Do not "fix" the iGPU by
copying the dGPU's MTP flags.

*Caveat worth knowing before re-testing:* these heads are `Q4_0` (59 MB) where the 26B's is
`Q8_0` (462 MB). A higher-precision drafter would raise acceptance. It would have to more
than double it to overcome a 25% deep deficit, so this was not pursued.

### E2B beats E4B on every axis — E4B was removed (2026-08-06)

**704 vs 481 t/s prefill, 14.3 vs 10.1 deep** — the smaller model wins by ~45% prefill and
~42% deep. At 53K context the gap widens: **443 vs 322 t/s** (121s vs 166s to ingest).
Consistent with the older "prefer dense at the small end" note: the E-series MoE expert
gathers are inefficient on this device, and E4B has more of them.

**`gemma-4-e4b` is gone — config, weights, projector and MTP head all deleted (2026-08-06).**
It was capable (4/4 tools, 4/4 quality, vision, needle at 53K, approval PASS) but strictly
slower than E2B on every axis while serving no role E2B did not already fill. **Its numbers
are kept in the table above precisely so it is not re-evaluated from scratch** — if it is
ever wanted back, re-download `gemma-4-E4B-it-Q4_K_M.gguf` plus `gemma-4-e4b-mmproj-F16.gguf`.

`mtp-gemma-4-E2B-it-Q4_0.gguf` (57 MB) is retained but **unreferenced** — MTP is rejected on
this tier, so it exists only to make a re-test cheap if a future llama.cpp changes the
verdict.

### `--ubatch-size 2048` is fine now — the old sweep is superseded

The old note here read *"128 → 104 t/s, 512 → 126, **1024 → 146 (best)**, 2048 → 136
(regresses)"*. **That no longer reproduces.** Re-measured 2026-08-06 without MTP, 3 rounds:

| ubatch | prefill | shallow | **deep** |
|---|---|---|---|
| 1024 | 672 t/s | 16.8 | **14.3** |
| **2048** | **704 t/s** | 17.1 | **14.3** |

Absolute prefill is ~5x the old sweep (146 → ~700), so the old numbers were measured on a
build and config that no longer exist. 2048 wins prefill in every round; deep is identical.
The margin is small and the 1024 arm shows a warm-up trend, so **treat this as a tie that
2048 wins on a tiebreak**, not a large effect.

### `f16` KV beats `q8_0` — take it for precision, not for speed

Prompted by [an Intel Arc benchmark write-up](https://jonathanmann.tech/blog/intel-arc-b70-llama-cpp-benchmarks/)
claiming f16 KV is right on Arc. Measured on the promoted config, 3 rounds:

| KV | prefill | shallow | **deep** | 53K needle |
|---|---|---|---|---|
| `q8_0` | 715 t/s | 17.0 | 14.4 | found, 464 t/s |
| **`f16`** | 727 t/s | 17.7 | **15.0** | found, 463 t/s |

**The speed claim does not survive scrutiny: +4% deep is inside noise.** f16's three deep
rounds were 15.0 / 15.3 / **13.3** — the last below every q8_0 round. At 53K the two are
identical.

**It is promoted anyway, on precision.** f16 KV is never worse, is strictly higher precision
at depth, and its 2x KV cost is *system RAM* on this tier, where 34 GB is free. Free upside
with a real quality argument beats a speed claim that does not replicate.

### Context scaling — this tier is much better than it used to be

The old table (6.5K → 558 t/s, 19K → 252, 50K → **485s to ingest**) was `qwen3.5-2b` on an
old build. `gemma-4-e2b` today: **53,567-token needle prefilled at 464 t/s in 115s**, found.
Still slower than the dGPU, but "485s to ingest 50K" is no longer the right mental model.

### Vision lives HERE now — the old "no vision" note was inverted

This section previously said *"Vision is absent because `local-vision` resolves to the
dGPU's far better model. The tier correctly rejects images."* **Both halves are now wrong.**
Since 2026-08-06 the dGPU runs `--no-mmproj` and **`local-vision` → `gemma-4-e2b` on this
tier**, with `gemma-4-e4b` as its fallback. Both carry projectors.

### Reasoning stays off — unchanged and still load-bearing

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
4. **`presence_penalty` 1.5-2.0 (Unsloth's recommendation) destabilises short factual
   output.** At temp 0.7 + pp 1.5 a 2B answered "17 times 4" as **56**; at temp 0, 68.
   The config uses 0.5.

**`--reasoning off` is a correctness requirement, not a speed tweak** — `local-tiny` backs
Hermes' `_smart_approve`, which sends `max_tokens=16` and expects one word. A thinking model
spends the whole budget reasoning and returns empty.

Caveat: `--reasoning off` removes reasoning waste, not verbosity. A vague prompt still
rambles to the cap; a well-specified one ("Reply with ONLY the title") answers in ~8 tokens.

**Re-proposed for the dGPU on 2026-08-09 and rejected on the evidence above.** The pitch:
subagent work (grep, read a file, decide yes/no) does not need a reasoning trace, so run a
second llama-swap entry at `--reasoning-budget 0`, or have Hermes pass it per-request.
Both halves are already disproven here — **point 1** (budget 0 measured *worse* than
thinking on) and **point 2** (per-request reasoning params silently dropped by LiteLLM's
`drop_params: true`). The underlying goal is sound; that mechanism is not.

The untested alternative is **`--chat-template-kwargs '{"enable_thinking":false}'`**, which
is a genuinely different mechanism — it stops the template opening a think block at all
rather than suppressing tag *parsing*. Live `/slots` confirms the current template
force-opens one: `"generation_prompt": "<|im_start|>assistant\n<think>\n"`. **Its cost is
the problem:** a second llama-swap entry means a full **22.66 GB no-mmap reload** on every
orchestrator↔subagent switch, almost certainly dearer than the thinking tokens it saves.
Only viable if children route to a different *tier*, not a different entry on the same one.

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

**Intel iGPU (Arc)** — SYCL via the upstream-tracking `:intel` image. `gemma-4-e2b` is
pinned resident via `groups:` with `swap: false`, because it backs **both** `local-tiny` and
`local-vision` — a title request and an image request must not evict each other. ~3.5 GB.

- **Cold-start:** the `intel_sycl_cache` volume (`/root/.cache`) persists the SYCL/Level-Zero
  JIT kernel cache. Without it every recreate recompiles all kernels — measured **4m32s**
  for the first request vs 18s warm. Client timeouts are usually shorter than that, so the
  first request after `up` can look like total failure (200 response, 0-byte body) while
  the backend is fine.
- **`--help` crashes without a GPU device** (SYCL init failure). Read flag docs from `:cuda`.
- **Memory:** reports free memory tracking host `MemFree`, not reclaimable `MemAvailable`.
  Check `free -h` before lowering ubatch.
- **ubatch and KV were re-measured on 2026-08-06** — see the tiny-tier section. The old
  sweep (peaking at 146 t/s, "2048 regresses") no longer reproduces; prefill is now ~700 t/s
  and 2048 is fine. KV moved `q8_0` → `f16`.
- **Bandwidth-bound, and that is why MTP loses here.** The device has no batching slack for
  speculative verification to exploit — the opposite of the CPU-offloaded dGPU.

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
  `--reasoning`, `--pooling`, `--embedding`, `--spec-type`, `--spec-draft-n-max`,
  `--load-mode`, `--no-mmproj`.
- **Available, not used, verified present on `:cuda` 2026-08-09** (`podman exec
  llama_swap_nvidia /app/llama-server --help`): `-kvu/--kv-unified`, `-cram/--cache-ram`
  (default **8192** MiB), `--cache-idle-slots` (default enabled, **requires cache-ram**),
  `-ctxcp/--ctx-checkpoints`, `-cms/--checkpoint-min-step`, `-sps/--slot-prompt-similarity`
  (default 0.10), `-lcs`/`-lcd` lookup caches, `--reasoning-budget`,
  `--chat-template-kwargs`. `--spec-type` takes a **comma-separated list** and offers
  `ngram-simple`, `ngram-map-k`, `ngram-map-k4v`, `ngram-mod`, `ngram-cache` alongside
  `draft-mtp` — stacking n-gram lookup onto MTP is untested here and plausible for agentic
  traffic, but MTP already accepts 77-78% at depth, so the headroom is small and this build
  has form for spec-decode settings that are not lossless in practice (see `n-max 3`).
- **Two flag facts that circulating advice gets wrong.** `-ctxcp/--ctx-checkpoints`
  **already defaults to 32** on this build — "raise it above the default of 8" is stale.
  And **`-cms` is `--checkpoint-min-step` (default 8192 tokens), not `--cache-reuse`**; the
  configs' `--cache-reuse 256` is an unrelated setting. The two get conflated constantly.
- **`--fit` is a no-op for this stack — tested, rejected (2026-08-06).** It only adjusts
  arguments you left *unset*, and every config here sets `--n-gpu-layers`, `--n-cpu-moe`
  and `--ctx-size` explicitly. The loader says so outright:
  `failed to fit params to free device memory: n_gpu_layers already set by user to 99, abort`.
  Making it meaningful would mean unsetting three values a documented sweep already
  optimised. It is periodically suggested online; the same thread's OP measured 30 t/s with
  `--fit` against 40 t/s with explicit placement.
- **Log format changed at b10257**: it now emits `srv llama_server: model loaded` instead
  of the classic `llm_load_tensors` / `buffer size` / `KV self` lines. Greps for the old
  strings make a healthy server look hung.

## Hermes wiring (`~/.hermes/config.yaml`)

Shared between both machines; names only aliases.

- `model.default: local-main`, `delegation.model: local-main`.
- `custom_providers[0].models.*.context_length` must be pinned. Without it Hermes reads
  `*.context_length` from GGUF metadata and advertises the native window (256K), overrunning
  the actual `--ctx-size` KV allocation.

| alias | pin | why |
|---|---|---|
| `local-main` | **131072** | matches the laptop dGPU default |
| `local-vision` | **131072** | since 2026-08-17 its laptop target is the remote `server-qwen38-27b` (128K ctx). Its iGPU fallback `gemma-4-e2b` only has 64K — an overflow there is a clean rejection, not a blind description |
| `local-tiny` | **65536** | its laptop target is `gemma-4-e2b` on the **iGPU**, which is 64K. Raising this overruns the iGPU. The tier ingests 53K in ~115s at 464 t/s — usable, but still ~2.5x slower than the dGPU, so a bigger window is not worth buying here |

**`local-main: 131072` matches the desktop (2026-08-15).** The desktop's `local-main` is
`qwen3.8-27b` at `--ctx-size 131072` (MTP 128K), so Hermes on the desktop is now aligned.
The laptop was deliberately moved first; the desktop followed once the new config was
promoted.

The old rule was "values are the **minimum across both machines**". That is still the safe
rule; this is a deliberate, temporary violation with a known consequence, not an oversight.

**`delegation.max_concurrent_children: 3` is currently aspirational (2026-08-09).** Every
llama-server here is `--parallel 1`, and on `local-main` that is forced by MTP, so children
serialize regardless of what this value says. It is not harmful — Hermes queues — but do
not read it as evidence that three children run concurrently. See
[Parallel subagents](#parallel-subagents--analysed-not-measured-2026-08-09) for what it
would cost to make it true.
- `auxiliary.<task>.{provider,model,base_url,api_key,timeout}` — `base_url` set explicitly
  on every one so they cannot silently fall back to openrouter.

Auxiliary tasks split on **critical path vs background**, not prompt size:

| tier | tasks |
|---|---|
| `local-main` | `compression`, `web_extract`, `mcp`, `skills_hub`, `kanban_decomposer`, `profile_describer`, `curator`, `monitor`, `memory_query_rewrite`, `triage_specifier`, `goal_judge`, `approval`* |
| `local-vision` | `vision` |
| `local-tiny` | `title_generation`, `tts_audio_tags` |

\*`approval` on `local-main` is a temporary operator override (2026-08-17, "until further
notice") — see the note below. The rest of this table matches the live config exactly; an
older revision had drifted.

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

Smart approval was silently broken while it pointed at `local-main`, and **it is there again
by operator decision (2026-08-17, "until further notice")** — a deliberate, documented
regression: on the medium-effort thinking model, `max_tokens=16` can go entirely to
reasoning and return empty content. Do not move it without raising `max_tokens` in upstream
code (or an explicit operator reversal). Caveat: `_smart_approve` would not fire from
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

## Clients must be told the window — they will not discover it

**OpenCode hit `request (72027 tokens) exceeds the available context size (65536)` at step
12.** Root cause was *not* prompt size; it was that **nothing told the client what the window
is**, so it never compacted and simply grew until the server refused.

Two fixes, both required:

- **`ai/litellm-config.laptop.yaml` now declares `model_info.max_input_tokens`** on every
  local entry (131072 dGPU, 65536 iGPU). Before this, `/v1/models` returned no token fields
  at all and every client was guessing.
- **`~/.config/opencode/opencode.json` now sets `limit.context` / `limit.output`** per model.
  Without it OpenCode never summarises. **A bigger window alone does not fix this** — it just
  moves the failure from step 12 to roughly step 22.

**Declared output caps follow one rule (2026-08-17):** `model_info.max_output_tokens` in the
LiteLLM configs (`litellm-config.laptop.yaml`, `litellm-config.server.yaml`) and
`limit.output` in `opencode.json` are **32K (32768) for models with a 128K window, 16K
(16384) for models with a 64K window**. Apply it to any new entry. The per-request cap
Hermes sends is separate and currently unpinned.

**Fallbacks cannot absorb a context overflow.** The same log shows LiteLLM failing over to
`gemma-4-26b`, which was also 64K, and failing identically. Every local model shares one
window by design, so a fallback list is the wrong tool for this failure.

**`context_window_fallbacks` — considered and rejected.** LiteLLM's own error suggests it,
and it looks ideal: overflow on the small window, auto-retry on a bigger one. It is
pathological here. Only one dGPU model is resident, so each escalation is a ~15-30s swap,
and the *next* turn routes back and swaps again — thrashing every message of a long session.
Worse, the small-window attempt must **load** the model before it can reject the request, so
each rejection costs a full ~18s load.

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
- **The server-side LiteLLM is in-repo and live — edit it here (2026-08-17).**
  `llama-cpp.yml` runs it as `litellm_server` (profile `server`, published :4000 →
  chat.gusev.tech) mounting `litellm-config.server.yaml`; it fronts `llama_swap_server` and
   exposes all three qwen3.8 effort variants (`qwen3.8-27b` / `-xhigh` / `-low`) plus
   `qwen3.6-35b`, and the aliases `server-qwen38-27b` / `-xhigh` / `-low` /
   `server-qwen36-35b`, which is what the laptop's remote entries resolve through.
  `litellm-config.desktop.yaml` is legacy — its `litellm_desktop` service is commented out in
  `llama-cpp.yml`; do not edit it.

## Operational gotchas

- **Editing a bind-mounted file replaces its inode**, so the container keeps serving the
  old one. `podman-compose up -d` is a no-op (nothing in the compose file changed) and
  llama-swap's own 2s config poll watches the stale inode. **`podman restart
  llama_swap_nvidia` is the fix** after any config edit.
- **`localhost` resolves to `::1` first.** llama-server binds IPv4 `0.0.0.0`, so podman's
  IPv6 forward accepts then resets — `Connection reset by peer`, which reads as a dead
  process. Use `127.0.0.1`. This also makes containers report `(unhealthy)` spuriously.
- **Thinking models return empty `content` on small budgets.** A 9B asked to "reply with
  just OK" spent 176 tokens reasoning first, and returned empty at `max_tokens: 16`.
  Give local models 400+, and 1200+ if the test must see an answer.
- **Only one dGPU model is resident.** `groups: swap: false` keeps multiple resident on the
  iGPU but the 8GB card cannot co-locate the large models — switching is an inherent
  ~15-30s swap.
- **Deliberately not used:** `--mlock` (fights llama-swap's TTL load/unload).
- **`healthCheckTimeout: 60` is too low — recommended, not yet landed (2026-08-09).** With
  `--load-mode none` the 22.66 GB GGUF is read from disk with **no mmap on every load**, and
  60s is not a safe budget for that on this laptop. If llama-swap kills a load mid-flight it
  looks like a mystery failure under agentic churn. **300** is the safe value, for both
  `llama-swap-nvidia.yaml` and `llama-swap-server.yml`. Raise it before running any
  benchmark sweep — it is a confound in every cold-load measurement.

## Benchmarking

**Every number in this file was produced by
[amidg/llm-benchmarking](https://github.com/amidg/llm-benchmarking)** — two stdlib-only
scripts (`smoke.py`, `llmbench.py`), no dependencies, no venv. It used to live at
`ai/bench/` and was split out so it can be pointed at any OpenAI-compatible stack.

Local checkout on this machine: `~/Projects/llm-benchmarking`.

### Setup

```bash
git clone git@github.com:amidg/llm-benchmarking.git ~/Projects/llm-benchmarking
cd ~/Projects/llm-benchmarking
export LITELLM_ENV=~/Projects/dockerfiles/ai/litellm.env   # or LITELLM_MASTER_KEY directly
```

On the **laptop** `LITELLM_ENV` is the only wiring needed — the scripts default to
`localhost:8081` (primary GPU), `:8082` (secondary) and `:4000` (gateway), which matches.
Without a key, `smoke.py --endpoint-only` still works.

On the **desktop** llama-swap is on host port **8080**, so `smoke.py`'s tier probe will
report the primary GPU unreachable. Either edit `TIERS` at the top of `smoke.py`, or use
`llmbench.py --endpoint http://localhost:8080/v1`. The gateway checks are unaffected —
LiteLLM is on 4000 on both machines, and going through aliases is the better test anyway.

### When to run what

```bash
./smoke.py                    # after ANY config edit, container restart, or model swap
./smoke.py --quick            # just show what is loaded where (no generation)

./llmbench.py --models qwen3.6-35b gemma-4-26b --tests perf --rounds 3
./llmbench.py --models qwen3.6-35b --tests all          # before promoting a config
./llmbench.py --models local-main --fail-on-regression  # CI gate
```

`smoke.py` is the gate after any change to this repo. It replays the exact `max_tokens=16`
approval shape and flags empty-content responses — that is how the smart-approval breakage
was found, and it is the one failure mode a "does it respond" check misses.

`llmbench.py --tests all` is what a config must pass **before being promoted** into
`local-main`: `tools` 4/4, `quality` no worse than the incumbent, and `vision` passing on a
real image.

### Reading its output against this stack

`llmbench.py --tests perf` prints `prefill`, `decode` and `deep`. **`deep` is the number
this stack is tuned on** — see [Decode is two numbers](#decode-is-two-numbers-and-mixing-them-wastes-days).
The `--n-cpu-moe`, thread and quant tables above are all `deep` figures at
`--perf-lines 320` (~6.5-8.6K prompt).

**`--perf-lines 2800` does not give ~58K — it gives 78,275 tokens and overflows a 65536
window**, failing every round with `request exceeds the available context size`. The real
rate is **~27.95 tokens/line**, so **use `--perf-lines 2100`** for ~58K.

Two harness bugs were found and fixed on 2026-08-06 (fixes are local in
`~/Projects/llm-benchmarking`, **not yet pushed upstream**):

- **`longctx` had never run.** Its `TESTS` lambda omitted `a.timeout` while every sibling
  passed it, so it raised `TypeError` on every invocation. That is why no longctx figure
  appears anywhere above.
- **`t_longctx` budgeted `max_tokens=64`**, violating the repo's own rule 4. On a thinking
  model the budget goes to reasoning and `content` comes back empty, so it reported
  `found: false` — a **false capability failure**. At 1200 both models retrieve the needle
  at 60% depth in 49,968 tokens. Now budgets 1200 and reports `empty` separately.

Its own `AGENTS.md` documents the interpretation traps in detail. The three that have
actually bitten this stack:

- **Give tests a thinking-model-sized budget.** `t_tools` and `t_quality` once ran at
  400/300 tokens; a model that spent the whole budget reasoning scored identically to one
  that answered wrong. A **3/4 where a different case fails each run is a budget problem,
  not a defect.** Both now budget 1200 and report `empty` separately.
- **Repeated identical prompts hit the prompt cache.** A single-model loop shows `ptok=4`
  on rounds 2+ and a meaningless prefill number. `llmbench.py` avoids this by alternating
  models, which flushes the cache — only round 1 is valid otherwise.
- **Vision must be tested with a real image** — see the vision floor above. Every
  configuration that crashed on an image passed a full 6524-token text prefill first.

### Practical notes for this hardware

- **Free the GPU first.** `curl -s -X POST 127.0.0.1:8081/api/models/unload`. A model left
  resident from a previous run skews the first measurement and can OOM a second load.
- **Long runs belong in the background.** `--tests all` across two 35B models takes 20-40
  minutes; model swaps (~15-30s each) dominate. Poll the output file rather than blocking.
- **Watch `free -h`, not just `nvidia-smi`.** `--n-cpu-moe` puts ~20 GB in system RAM, and
  the Arc allocates against `MemFree`. Memory pressure has killed the whole stack mid-run.
- If you tune anything, **update the tables in this file in the same commit**, with the
  measurement that produced the change.

```bash
curl -s 127.0.0.1:8081/v1/models | jq '[.data[]|{id,status:.status.value}]'
podman logs --tail 20 llama_swap_nvidia
nvidia-smi --query-gpu=memory.used,memory.total --format=csv
free -h                                          # iGPU "VRAM" is host RAM
curl -s -X POST 127.0.0.1:8081/api/models/unload  # free the GPU between runs
```
