# AGENTS.md — local LLM stack

Everything non-obvious about this stack lives here. Read before editing any config.

## Document structure — where things belong

| file | contains | audience |
|---|---|---|
| `README.md` | how to run it, endpoints, a handful of headline numbers | humans |
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

Two machines. The laptop runs llama-swap (one config per device, one `llama-server`
subprocess per model); the desktop runs a single resident Strata process. Each advertises
only what its device can run.

| config | container | device | port | models |
|---|---|---|---|---|
| `llama-swap-nvidia.yaml` | `llama_swap_nvidia` | RTX 5070 8GB (laptop) | 8081 | `tiel-coder-35b` (MTP, 128K, UD-Q4_K_XL body + Q3_K_S head, N=35, temp 0.6), `lfm2.5-24b` (131K, QAD Q4_0, N=24, **no MTP**, ttl 0), `gemma-4-e4b` (MTP, vision, 128K, qat, q8_0 KV) |
| `llama-swap-intel.yaml` | `llama_swap_intel` | Arc Pro iGPU (laptop) | 8082 | `gemma-4-e2b` (background tasks), `embeddinggemma-2` (embeddings) |
| `ai/Strata` (submodule) | `strata` | 5070 Ti 16GB (desktop) | 8080 | `qwen3.8-flash-next` (**IQ2_XS, Strata**, 131K, `k8v4` KV, vision, arena pinned in 96GB RAM) |

## Strata on the desktop — promoted 2026-10-17

The desktop stopped running llama.cpp. It runs **Strata** (git submodule `ai/Strata`,
pinned to a release tag; built by `podman-compose -f ai/llama-cpp.yml --profile server up -d
--build` with `CUDA_ARCHITECTURES=120`) serving **Qwen3.8-Flash-Next GSQ-RCO IQ2_XS** — a
125B-A6B MoE with a ~51B n-gram (PLE) table and a bundled MTP draft layer.

| | |
|---|---|
| GPU | 5070 Ti 16GB — the container is CUDA-only (`FROM nvidia/cuda:13.0.0`) |
| 7900 XTX | **display only.** Mixed HIP+CUDA in one Strata run is unsupported (`docs/MULTI_GPU.md`, `docs/AMD_HIP.md`), and the container ships no ROCm |
| RAM | `STRATA_ARENA_PIN_GIB=40` of 96GB quad-channel; the arena is page-locked, so `ulimits.memlock: -1` is mandatory |
| SSD | `/mnt/data/llama/strata` → `/data` — n-gram table, MTP draft, pack, config |
| context / KV / vision | `131072` / `k8v4` / `yes` |
| gateway name | `qwen3.8-flash-next` — desktop LiteLLM → `http://strata:8080/v1`, no API key; the gateway holds the master key |

**Why Strata and not llama.cpp.** No quant of this model fits 16GB VRAM (the smallest
published GGUF is 72.5GB), so it only runs tiered, and Strata is built for exactly that
partition — hot experts in VRAM, the rest of the arena pinned in RAM, the n-gram table on
the SSD. llama.cpp has no equivalent residency model.

**NVFP4 was evaluated and rejected, despite the 10980XE's AVX-512.** Per `docs/NVFP4.md`
and issue #2347: the NVFP4 packs are 128GB on disk, carry ~63.3GiB of experts, and want
**~80GB of RAM** for the arena — over budget at a 40GiB pin. It also decodes *slower* than
IQ2_XS (114 vs 132 tok/s on a 5090), because FP4 tensor cores accelerate only the prompt
path (`w4a4`, sm_120a). AVX-512 cleared the CPU-side objection (AVX2-only hosts were
refused on 0.1.44/44.1), not the RAM one. Upgrade path if RAM ever goes past ~96GB:
`--family nvfp4 --model NVFP4` — and note decode, not prefill, is what that trade costs.

**Quant: IQ2_XS, the largest that fits the budget.** The project's own 16GB-card
recommendation. GSQ-RCO is the supported family (`Q2_0 | IQ2_XS | IQ3_XXS | IQ3_S`);
IQ3_XXS lands near the 40GiB arena cap with no margin, so it is the first thing to try
after a RAM increase — not before. KV is `k8v4`; step down to `int8` then `q4_0` only if a
131K prompt OOMs.

**Weights are user-supplied, not downloaded.** `GGUF_DIR=/models` with the IQ2_XS shards
under their original names plus `mmproj-Qwen3.8-Flash-Next-BF16.gguf`. Strata writes
`<shard>.done` checksum markers next to them, so the models dir is mounted writable (this
is also why it is not `:ro` here while every llama-swap mount is). The MTP draft is the
only file Strata fetches itself, into `/data`; the engine is never re-downloaded after the
image build.

**Not yet verified anywhere — the migration was delivered dry.** Three first-boot checks
live in the README: (1) podman CDI wiring — upstream documents `--gpus all` for Docker and
never mentions podman, so `base_nvidia`'s reservation is the first thing to prove or
replace with `nvidia-ctk cdi generate` + `--device nvidia.com/gpu=all`; (2) the arena
actually pinning ~36-40GiB while the desktop stays responsive; (3) the model id Strata
advertises on `/v1/models`, which must match the LiteLLM `model:` field.

**Known risk, accepted:** port 8080 is published with **no API key**, so anything on the
LAN can reach an unauthenticated OpenAI endpoint. LiteLLM :4000 (master key) is the
supported path; binding 8080 to loopback is the fix if it ever matters.

**The laptop side is deliberately untouched (2026-10-17).** `litellm-config.laptop.yaml`
still routes `server-qwen3.8-27b` and `server-qwen3.6-35b` at `api.gusev.tech`, and neither
exists on the desktop anymore — it serves only `qwen3.8-flash-next`. Rewiring the laptop's
remote entries (and the Hermes/opencode pins) is a separate, explicitly deferred change.


### Qwen3.8-27B on 7900 XTX 24GB — retired 2026-10-17

*(Superseded by [Strata on the desktop](#strata-on-the-desktop--promoted-2026-10-17). The
tuning numbers below are kept so the dense-27B path is not re-evaluated from scratch.)*

MTP 128K, Vulkan backend on AMD RDNA3. Quant: IQ4_XS. KV quant: `q5_0`/`q4_1`. Harness
uses `chat_template_kwargs: {"reasoning_effort": "low"}`. Reasoning efforts can be set per
request and should be embedded into the agentic harnesses. Available levels are:
- xhigh (default): for complex tasks demanding thorough analysis
- medium: balancing accuracy and speed
- low: efficient reasoning optimizing for speed and cost
- none

**Decision: one llama-swap entry, effort chosen per request (2026-08-24).** Supersedes the
three-sibling layout (`qwen3.8-27b` / `-xhigh` / `-low`, 2026-08-18), which existed only
because per-request `reasoning_effort` was being dropped by the gateway. It wasn't a
LiteLLM limitation — it was a missing `allowed_openai_params` (see [LiteLLM](#litellm)).
With the param flowing, three identical instances buy nothing and cost a lot: one 24GB card
cannot co-locate two ~16GB instances, so **every effort switch was a full cold load**. Now
it is a request field.

`--chat-template-kwargs '{"reasoning_effort":"medium"}'` **stays** on the single entry — it
is the Unsloth-documented way to set Qwen3.8's effort and is the correct *default* for
clients that send nothing (Open WebUI). llama.cpp resolves effort in a fixed order
(`tools/server/server-common.cpp`): server `--chat-template-kwargs` → request
`chat_template_kwargs` → **request top-level `reasoning_effort`, applied last and winning
over both**. So the baked default and per-request override are complementary, not rivals.

Two consequences worth knowing:
- **`reasoning_effort: "none"` sets `enable_thinking = false`** outright and erases the
  kwarg — a genuine per-request off switch, and specifically *not* the
  `--reasoning-budget 0` failure mode documented below.
- **Stay inside `xhigh | medium | low | none`.** llama.cpp's CLI also accepts
  `minimal`/`high`/`max`, but Qwen3.8's template defines only the three levels; anything
  else is off-vocabulary. Hermes' ladder (`VALID_REASONING_EFFORTS`) is wider than this —
  don't use the extra levels here.

The old `groups: swap: false` pin stays removed (pinned members are never evicted, which
would have made a second instance unloadable). The entry remains `ttl: 0`.

**Measured through both LiteLLM hops (2026-08-24, n=3 per level, one hard reasoning
prompt, `max_tokens=4096`).** Model runs at `--temp 1.0`, so single samples are noise —
these are means:

| effort | reasoning chars | completion tokens |
|---|---|---|
| `none` | **0** | answers directly in `content` |
| `low` | 1535 | 860 |
| `medium` | 1615 | 1165 |
| `xhigh` | **12226** | 3551 (2 of 3 hit the 4096 cap) |

**The ladder is not linear — it is flat-ish then a cliff.** `low`→`medium` is ~5%
reasoning; `medium`→`xhigh` is ~7.6x. Budget for `xhigh` accordingly: it will hit a
4096-token cap on a hard prompt. On an *easy* prompt all three of `low`/`medium`/`xhigh`
collapse to ~310-380 reasoning chars — effort is a ceiling, not a floor, so do not
benchmark it on trivial questions (an earlier run did exactly that and looked like the
param was being ignored).

`chat_template_kwargs: {"reasoning_effort": ...}` measures the same as the top-level field
(`low`: 1680 vs 1535 chars, within noise) — both land on the same template variable, as the
precedence code above implies. Prefer the top-level field: Hermes can only send that one.

A `qwen3.6-35b` (MTP + vision, **no `--n-cpu-moe`**) entry joined this same box on
2026-08-18. One ~16GB Qwen3.8 plus a 22.66GB MoE still exceeds one 24GB card, so at most
one model is resident and a **cross-model** switch costs a full cold load — that cost is
unavoidable and is exactly what collapsing the effort siblings removed from the
*within*-model case. It shipped at `--n-cpu-moe 15`, then 5 — see the section below for
why both were wrong.

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

Host ports: **8081 primary GPU, 8082 secondary, 8083 whisper (Intel NPU)** on the laptop;
the desktop's **Strata is on 8080** (no Open WebUI anywhere since 2026-10-17). Both
machines run their gateway on 4000 — they are separate hosts, so there is no conflict.

Container-internal ports are always 8080, which is why `litellm-config.*.yaml` points at
`http://llama_swap_*:8080/v1` (laptop) or `http://strata:8080/v1` (desktop) regardless of
the host mapping. Changing a host port does not require a LiteLLM change.

**The laptop runs nvidia + intel concurrently.** They used to share a container name and
port via the `base_llama_swap` anchor, which made them mutually exclusive. `container_name`,
`ports` and the config mount are per-service now — do not move them back into the anchor.

Request flow: agents → LiteLLM (`:4000`) → llama-swap (`:8081`/`:8082`) → a `llama-server`
subprocess per model, **on the laptop only**. The desktop's flow is agents → LiteLLM →
Strata (`:8080`) → one long-resident process (no per-model spawn, no TTL). GGUFs live in
`${LLAMA_MODELS_DIR:-~/.llama/models}`, mounted at `/models` (this laptop:
`/mnt/data/llama/models`).

### Qwen3.6-35B-A3B on 7900 XTX 24GB — retired 2026-10-17

*(Superseded by [Strata on the desktop](#strata-on-the-desktop--promoted-2026-10-17); the
`--n-cpu-moe` findings below still explain why desktop llama.cpp tuning never transferred.)*

**Decision: no `--n-cpu-moe` at all, `--ubatch-size 1024`, and the Qwen3.6 thinking-mode
*precise-coding* sampler — `--temp 0.6`, no presence penalty.** `53.0 → 177.6 t/s deep, a
3.35x gain`. Three changes, and **only two of them were performance fixes**: dropping
`--n-cpu-moe` (2.84x) and dropping `--presence-penalty 1.5` (1.18x). The temperature move
`1.0 → 0.6` is a **quality** decision for this box's coding workload and costs nothing
measurable — do not cite it as a speed change.

| config | prefill | shallow | **deep** | acc s/d |
|---|---|---|---|---|
| as-shipped (`-ncmoe 5`, ub2048, `-presence-penalty 1.5`) | 2265 t/s | 43.4 | **53.0** | 57%/75% |
| `-ncmoe 5`, ub1024 | 1989 t/s | 44.2 | **54.1** | 53%/76% |
| `-ncmoe 3`, ub1024 | 2177 t/s | 59.6 | **66.7** | 59%/75% |
| `-ncmoe 1`, ub1024 | 2488 t/s | 82.1 | **89.4** | 53%/72% |
| **no `-ncmoe`**, ub1024 | 2094 t/s | 142.7 | **150.4** | 60%/73% |
| **promoted: no `-ncmoe`, ub1024, `--temp 0.6`, no penalties** | **2115 t/s** | **163.2** | **177.6** | **63%/80%** |

**`--n-cpu-moe` is catastrophic on this box, and the laptop's rule inverts.** The laptop
tier buys VRAM headroom with N because there N is nearly free; here **every single expert
layer left on the CPU costs ~2.4-4.5 ms per token**, against a 6.65 ms total token budget
when all 40 are on the card. One layer costs ~40%. Even `N=1` gives up 41% of decode.

The cost is **per layer, not per byte** — `--ubatch-size 2048 → 1024` at fixed `N=5`
changed nothing (53.0 → 54.1), so this is not the compute buffer and not bandwidth. It is
the GPU→CPU→GPU round trip that every CPU-resident expert layer forces on every token,
multiplied by MTP verifying 2-3 tokens per step. Diagnosis before the sweep: **3.33 GiB of
VRAM sat free while 2.14 GiB of experts sat in GTT** (`mem_info_gtt_used`) — the card had
room for all of them and was not being given them.

**Why the laptop's tuning does not transfer.** The desktop is a Ryzen 7 5800X on
dual-channel DDR4 (~45-50 GB/s); the laptop is LPDDR5x at roughly twice that. A
CPU-resident expert layer is therefore ~2x more expensive here — and the card is 24GB, so
unlike the 8GB laptop it never had to pay. `--n-cpu-moe` on this box is a pure loss with
no compensating benefit. **Do not copy N between tiers.**

**`--presence-penalty 1.5` costs 15% of deep decode. Temperature is free.** The shipped
entry carried the *instruct* row's presence penalty inside an otherwise *thinking*-row
sampler. Isolated at `N=0`/ub1024, one axis at a time:

| sampler | deep | accept s/d |
|---|---|---|
| `--temp 1.0 --presence-penalty 1.5` (as shipped) | 150.4 | 57%/**73%** |
| `--temp 1.0 --presence-penalty 0.0` | 177.7 | 61%/**80%** |
| `--temp 0.7 --presence-penalty 0.0` | 177.6 | 63%/80% |
| **`--temp 0.6 --presence-penalty 0.0`** (promoted) | **177.6** | 63%/**80%** |

**The whole gain is the penalty; temperature does nothing at all** — 177.6/177.7/177.6 and
a flat 80% acceptance across 1.0, 0.7 and 0.6. The mechanism is specific to speculative
decoding: a presence penalty is a context-dependent, position-varying shift on logits the
MTP draft head does not model, so its proposals get rejected (**80% → 73%**). Temperature
scales logits monotonically and leaves the verification ordering intact. An earlier
revision of this section blamed temperature as well — that was wrong, and it was wrong
because the first sweep moved temperature and the penalty together.

**Consequence: on an MTP config a penalty is a speed setting; temperature is not.** Pick
temperature on quality grounds alone, and note that `llmbench` cannot help — `t_quality`
and `t_longctx` pass `temperature=0` explicitly (`llmbench.py:347,365`), overriding the
server sampler, so this harness measures the sampler's effect on speed and acceptance and
**never on quality**.

**The Unsloth Qwen3.6 recommendation** (https://unsloth.ai/docs/models/qwen3.6) is the
authority, and neither the shipped config nor the first promoted attempt matched it:

| mode | temp | top_p | top_k | min_p | presence | repeat |
|---|---|---|---|---|---|---|
| thinking, general | 1.0 | 0.95 | 20 | 0.0 | **0.0** | 1.0 |
| **thinking, precise coding (promoted)** | **0.6** | 0.95 | 20 | 0.0 | **0.0** | 1.0 |
| instruct (non-thinking) | 0.7 | **0.8** | 20 | 0.0 | **1.5** | 1.0 |

**The rows are not mix-and-match** — that splice is exactly what cost 15%. A first attempt
promoted `--temp 0.7 --top-p 0.95`, which matches neither row (0.7 is the instruct
temperature, 0.95 the thinking top_p); it came from `llama-swap-nvidia.yaml`, not from any
Qwen3.6 source. `--presence-penalty 0.0 --repeat-penalty 1.0` are written explicitly even
though they are llama.cpp defaults: in a comment-free config that is the only record that
their absence is deliberate.

**The precise-coding row is the promoted default** because this box serves coding agents,
and the choice is free: 0.6, 0.7 and 1.0 all measure 177.6-177.7 deep at 80% acceptance.
Moving to the general row is a **temperature-only edit** with no throughput consequence, so
decide it on output quality, not on this table. Note that `llmbench` cannot settle that
either — see the `temperature=0` caveat above.

**The penalty finding is corroborated independently in this file.** The tiny tier already
records *"`presence_penalty` 1.5-2.0 (Unsloth's recommendation) destabilises short factual
output"* — a 2B answered "17 times 4" as 56 at pp 1.5, and 68 at pp 0. That was a
correctness observation on a different tier; this is the same parameter costing **15% of
throughput and 7 points of draft acceptance** on an MTP config. `presence_penalty 1.5`
has now hurt this stack twice, on two axes, on two tiers.

**Unchecked, same shape:** all three `qwen3.8-27b` entries carry `--temp 1.0 ...
--presence-penalty 1.5`. If the Qwen3.8 page splits thinking/instruct the same way, they
have the same splice and the same ~15% on the table. Not verified — that is a different
model with a different page, and it needs its own sweep before anyone touches it.

**Rejected, measured:** `--threads 8` (150.8 vs 150.7 — with no CPU expert work, threads
are irrelevant on this tier; the laptop's thread sweep does not apply either) and
`q8_0/q8_0` KV (150.2, acceptance 72% — buys nothing and costs VRAM; KV is already cheap
on this hybrid).

**MTP still earns its place, but for a different reason than on the laptop.** Control with
`--spec-type` removed: **113.5 deep vs 150.7, a 1.33x gain** — squarely in the 1.17-1.40x
band the community reports for a *fully GPU-resident* A3B, versus 1.53x when the experts
were CPU-bound. The prefill trade the upstream PR predicted also finally appears here:
**MTP now costs 28% of prefill** (2890 t/s without it, 2080 with), because the baseline is
no longer gated by the CPU expert gather. Both numbers move exactly as *Why the published MoE numbers
understate this machine badly* predicts — that section describes the laptop's regime, and
this box is now in the other one.

**Gate** (run on the exact promoted flag set, alternating against `qwen3.8-27b`):
`tools` 4/4, `quality` 3/4 (identical to the incumbent — the known `terse_title` budget
case), `vision` yes. Vision was additionally checked with a **real 1280x1280 image**,
not just `llmbench`'s 1x1 PNG: 1623 prompt tokens, reads the word, `finish: stop`. The 1x1
PNG proves the projector loads and almost nothing about the encoder's compute buffer — at
`N=0` this config has less headroom than the one the vision floor was measured on.

**Not yet measured:** `--load-mode none` was promoted on the laptop because *experts were
CPU-resident* and mmap indirection sat on the expert-gather path. No expert is CPU-resident
here, so that rationale no longer applies and plain mmap may cost nothing while making
llama-swap's cold loads cheaper. Untested — do not assume either way.

## Direct naming (2026-08-25)

Aliases are gone. Agents, Hermes, and opencode now reference models directly:

| resolved name | source | use |
|---|---|---|
| `qwen3.8-flash-next` | desktop (5070 Ti, Strata, 131K, vision) | main agent, delegation, vision, anything user-facing |
| `lfm2.5-24b` | laptop dGPU (RTX 5070, 131K, QAD Q4_0, N=24, no MTP, ttl 0) | fast local agent, long-context local work |
| `tiel-coder-35b` | laptop dGPU (RTX 5070, MTP, 128K, Q4_K_XL/Q3_K_S, N=35, temp 0.6) | local coding agent (promoted 2026-10-17) |
| `gemma-4-e4b` | laptop dGPU (RTX 5070, MTP, 128K, qat, q8_0 KV, vision) | fast GPU-resident work, background, **auxiliary tasks**, vision |
| `gemma-4-e2b` | laptop iGPU (Arc, 64K, no MTP, --reasoning off) | background/fire-and-forget, vision fallback |
| `embeddinggemma-2` | laptop iGPU (Arc, 8K ctx, embeddings only) | embeddings |

- **The desktop name changed 2026-10-17: `server-qwen3.8-27b` → `qwen3.8-flash-next`.**
  The old dotted name and `server-qwen3.6-35b` are gone from the desktop; the laptop config
  still lists them and is scheduled for a separate rewiring (see
  [Strata on the desktop](#strata-on-the-desktop--promoted-2026-10-17)). `~/.hermes/config.yaml`
  and `~/.config/opencode/opencode.json` must be re-pointed to `qwen3.8-flash-next` on the
  desktop side, and unset on the laptop side until its rewiring lands. The name is direct —
  no `server-` prefix, no aliases — like everything else.

- **`ornith-1.5-9b` is retired (2026-10-17).** Too weak to figure tasks out in practice; the
  fast GPU-resident slot is `gemma-4-e4b`, which is multimodal and does the same jobs better.
  Removed from `llama-swap-nvidia.yaml`, `litellm-config.laptop.yaml`, `~/.hermes/config.yaml`
  (its `skills_hub` / `approval` / `mcp` tasks → `gemma-4-e4b`) and `opencode.json`; the GGUF
  (6.5 GB) is deleted. If a fast 9B is ever wanted again, note it was the *only* thing at 64K
  on the dGPU — everything current runs 128K.

- **Two spellings of the server names existed; one is gone.** The laptop
  (`litellm-config.laptop.yaml`, Hermes, opencode) still uses the dotted
  `server-qwen3.8-27b` / `server-qwen3.6-35b`; the desktop's `litellm-config.server.yaml`
  and its `model_group_alias` entries were deleted on 2026-10-17. The desktop now serves
  `qwen3.8-flash-next` and nothing else. **The dotted form survives only as the laptop's
  stale remote entry** and dies with the deferred laptop rewiring.
- **Only one dGPU model is resident at a time (~15-30 s swap).** The RTX 5070 carries
  `lfm2.5-24b`, `tiel-coder-35b` and `gemma-4-e4b`; requesting a different one
  evicts the loaded model. All three run 128K; `lfm2.5-24b` is `ttl: 0` — it
  never *idle*-unloads, but that does not exempt it from a cross-model swap.
- **`gemma-4-e4b` runs the QAT variant** (`gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf`) with its own
  projector (`gemma-4-e4b-qat-mmproj-F16.gguf`). KV cache: `q8_0` (7432 MiB total).
  MTP head is shared with the non-QAT variant (`mtp-gemma-4-E4B-it.gguf`).
  Smaller KV cache types (q5_1) caused memory spill to system RAM and halved decode speed.
  Full benchmark pending.
- **`gemma-4-e4b` MTP head** is `mtp-gemma-4-E4B-it.gguf` (95 MB) — separate file like the
  26B, not bundled in the GGUF. `embedding_length_out` must match the target's `n_embd`.
- **`qwen3.8-flash-next` is the only vision model on the main tier.** It carries a
  `mmproj-Qwen3.8-Flash-Next-BF16.gguf` projector. `gemma-4-e2b` is the fallback — also has
  a projector. A blind model confidently describing an image is worse than a clean error.
  When deleting a vision model, **re-point the fallback in the same change**.
- **`embeddinggemma-2` is now wired on the laptop.** `llama-swap-intel.yaml` defines it
  in the `igpu` group with `--pooling mean --ctx-size 8192`, and `litellm-config.laptop.yaml`
  exposes it as `embeddinggemma-2`. Anything calling `/v1/embeddings` on the laptop should
  route through it. Do not "fix" it by pointing an entry at a chat model — a chat
  deployment cannot serve `/v1/embeddings`.

## Bifrost — evaluated and rejected (2026-08-24)

Migrated the gateway to Bifrost (`maximhq/bifrost`), ran it on `:4000` for a day, then
reverted. The motivation was per-request `reasoning_effort`, which LiteLLM was dropping
(see [LiteLLM](#litellm)). **Bifrost cannot carry that param for these models**, which
removed the only reason to switch:

- `reasoning_effort` is a *known* field: Bifrost parses it into
  `ChatParameters.Reasoning.Effort` and rewrites it in `normalizeOpenAIReasoningEffort()`
  (`core/providers/openai/utils.go`). `xhigh` is honoured **only for GPT-5.x** and
  downgraded to `high` for everything else (maximhq/bifrost#4460). Qwen3.8's template
  defines `xhigh`/`medium`/`low` and **not** `high`, so the downgrade lands off-vocabulary.
- `x-bf-passthrough-extra-params: true` does **not** rescue it. Passthrough applies to
  unknown extra params; a known field is normalized regardless. Routing the effort through
  `chat_template_kwargs` instead does survive, but only opencode can send that shape —
  Hermes' main turn emits the top-level field and has no `extra_body` hook (only
  auxiliary tasks do), so half the fleet would still be broken.

Secondary deltas, all survivable, none worth the above: no config-level cross-tier
`fallbacks:` (only per-request `"fallbacks": [...]`), no per-key spend tracking, and
`/v1/models` may not advertise token limits.

**Do not re-attempt without first checking whether `normalizeOpenAIReasoningEffort()`
still rewrites non-GPT-5 efforts.** That single function is the whole blocker.

## Measured performance (laptop)

Absolute values drift 20-30% with load and thermals — **only compare models measured in
the same session.** Ratios have been stable across every repetition.

| device | model | prefill | decode (deep) | VRAM |
|---|---|---|---|---|
| RTX 5070 | `lfm2.5-24b` **(QAD Q4_0, N=24, no MTP, 131K, ttl 0)** | **1804 t/s** | **37.3 t/s** (41.3 decode), 45.9K @1732 t/s | ~7278 MiB |
| RTX 5070 | `tiel-coder-35b` **(promoted, MTP, 128K, N=35)** | **897 t/s** | **40.5 t/s** (38.1 shallow), acc 47%/55% | ~7402 MiB, RSS 18.6 GB |
| RTX 5070 | `qwen3.6-35b` *(retired 2026-10-17; MTP, 128K)* | 991 t/s | 46.3 t/s (41.2 shallow), 36.9 @118K | ~7275 MiB |
| RTX 5070 | *no-MTP control* **(arm removed)** | 410 t/s | 29.7 t/s (35.3 shallow) | ~6100 MiB |
| RTX 5070 | `gemma-4-26b` *(retired; MTP, vision, 128K)* | 1267 t/s | 26.3 t/s (25.3 shallow) | ~7105 MiB |
| RTX 5070 | `gemma-4-e4b` *(MTP, vision, 128K, qat, q8_0 KV)* | **3275 t/s** | **110-112 t/s** | ~7432 MiB |
| Arc iGPU | `gemma-4-e2b` | **713 t/s** | **14.4 t/s** (17.4 shallow) | ~3.5 GB RAM |
| Arc iGPU | `embeddinggemma-2` | embeddings only | — | ~3.5 GB RAM |
| Intel NPU | `whisper-small-int4` (ASR, not an LLM) | — | ~4.2 s / 60 s clip | RAM |

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

### Gemma 4 E4B QAT — fastest decode on 8GB (2026-08-25)

The QAT variant (`gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf`, 4.0 GB) with its own projector
(`gemma-4-e4b-qat-mmproj-F16.gguf`) and `q8_0` KV cache: **7432 MiB total VRAM**, MTP
51%/70% acceptance at **110-112 t/s decode**, **3275 t/s prefill**. Nearly 2x qwen3.6-35b
decode despite being ~1/80th the size — dense model, no CPU expert gather penalty, and
the RTX 5070's bandwidth is fully utilized. Smaller KV cache types (q5_1) caused memory
spill to system RAM and halved decode speed; `q8_0` stays entirely in VRAM. Full
`llmbench.py --tests all` benchmark pending.

**Benchmark note:** when testing a single model, `llmbench.py` rounds 2-3 report ~100 t/s
prefill — this is a prompt cache hit artifact, not real prefill. Always test with ≥2
models so the alternation flushes the cache and every round measures cold prefill.

### LFM2.5-24B-A2B on RTX 5070 8GB — promoted config (2026-10-17)

**`lfm2.5-24b` beats the MTP incumbent on every axis, without MTP.** Head-to-head against
`qwen3.6-35b`, same session, 3 rounds, `--tests perf tools quality longctx`:

| model | prefill | decode | **deep** | tools | quality | longctx |
|---|---|---|---|---|---|---|
| **`lfm2.5-24b`** (QAD Q4_0, N=24) | **1804 t/s** | 41.3 | **37.3** | 4/4 | 4/4 | 45.9K @ **1732 t/s** (26.5 s) |
| `qwen3.6-35b` (MTP, N=35) | 883 t/s | 30.8 | 34.6 | 4/4 | 4/4 | 50.0K @ 891 t/s (56.1 s) |

**2.0x prefill, +34% decode, +8% deep, ~2x long-context ingest**, equal tools and quality.
Round 1 is a warm-up outlier for both (659/23.8 and 522/25.9) — compare within the session,
as always.

Config: `LFM2.5-24B-A2B-QAD-Q4_0.gguf` (13.58 GB), `--n-cpu-moe 24`, `--ctx-size 131072`,
`--ubatch-size 1024`, q4_0/q4_0 KV, `--load-mode none`, `--threads 6 --cpu-range 0-5
--cpu-strict 1`, **no `--spec-type`** (no draft head exists for this model), `--no-mmproj`
(text-only), `ttl: 0`. **7278 MiB VRAM, 873 MiB free, RSS 8392 MiB**, cold load 12-17 s.
RSS is the number that does not show in `nvidia-smi` and it matters here: **8392 MiB against
the 35B's 19.4 GB**, so ~11 GB of system RAM is handed back on this tier.

**QAD Q4_0, not Q4_K_M — and the "Q4_K_M is the floor" rule does not apply to it.** That rule
is about 3-bit K-quants and i-quants, whose *CPU* dequant cost outweighs the bytes they save
when experts are CPU-resident. Q4_0 is the cheapest 4-bit CPU dequant path, and this file is
quantization-aware-*distilled* — trained to recover Q4_0's accuracy — so it is a different
trade, not a smaller quant. Q4_K_M for this model is untested; bench it only if this file
fails a quality gate.

**N is calibrated, not inherited: ~322 MiB per expert layer on the GPU.** Measured by delta —
N=26 → 6634 MiB, N=24 → 7278 MiB — so **16 of the 40 expert layers are on the card**. N=22
would be ~7900 MiB / ~229 MiB free, inside the crash zone this stack has hit twice, and the
no-MTP sweep says two layers is worth ~0.2 t/s: **N=24 is the optimum, not a waypoint.** The
`N=35` below belongs to `qwen3.6-35b`; do not copy it.

**MTP is not required to win this tier.** `qwen3.6-35b` needs its draft head to reach 34.6
deep; LFM2.5-24B reaches 37.3 without one, because 2.3B active parameters plus 16
GPU-resident expert layers outrun the 35B's 35 CPU-resident ones. MTP stays the biggest win
*available to a given model* — see [MTP](#mtp--the-single-biggest-win-on-this-tier-2026-08-06) —
not a precondition for a fast laptop tier.

**`ttl: 0` pins against idle eviction only.** A request for `tiel-coder-35b` or
`gemma-4-e4b` still evicts it (8GB cannot co-locate them); it buys residency, not exclusivity.
Cold load is a one-off `--load-mode none` read of 13.58 GB.

**LiteLLM deliberately does not allowlist `reasoning_effort` for this model.** See
[LiteLLM](#litellm). It thinks before answering and prefixes `content` with a blank line, so
the `max_tokens=16` approval shape comes back empty — and would not string-match `APPROVE`
even if non-empty. **Do not point `approval` at it** without the `reasoning_effort: none`
treatment.

### Tiel-Coder-35B-A3B — evaluated, rejected on speed (2026-10-17)

`Tiel-Coder-35B-A3B-MTP-UD-Q4_K_XL.gguf` (22.75 GB, Q3_K_S MTP head, Sharp v22.5.0 template)
was benched as the coding-agent candidate against both incumbents, same session, 3 rounds,
`--tests perf tools quality approval thinking longctx` (no `vision` — its `--no-mmproj` is
deliberate; vision belongs to the iGPU tier). It **passes every correctness check and fails
every performance one**:

| model | prefill | shallow | **deep** | acc s/d | tools | quality | longctx |
|---|---|---|---|---|---|---|---|
| `tiel-coder-35b` (MTP, N=35) | 894 t/s | 34.8 | **37.5** | 46%/55% | 4/4 | 4/4 | 50.2K @ 891 t/s |
| `lfm2.5-24b` (no MTP, N=24) | **1918 t/s** | 43.7 | **44.7** | — | 4/4 | 4/4 | 45.9K @ 1805 t/s |
| `qwen3.6-35b` (MTP, N=35) | 939 t/s | 43.1 | **46.9** | **68%/78%** | 4/4 | 4/4 | 50.0K @ 929 t/s |

VRAM 7402 MiB (749 free), RSS **18555 MiB**, thinking clean (205 reasoning chars, content
non-empty — terser than LFM's 1039). Through the gateway with `reasoning_effort: "none"` it
returns `APPROVE` in 4 tokens, `finish: stop` — **the Sharp template honours the effort
ladder and the allowlist works**, so the approval-shape trap that hits LFM/`gemma-4-e2b` does
not apply here.

**Why it loses: MTP acceptance, not quant mix.** The main-body expert types are *identical*
to `qwen3.6-35b` (blk.39 `{Q3_K_M, Q4_K_S}`), and prefill is within 5% — so the file is not
a "smaller quant" problem. Decode is ~20% down because its draft head verifies at **46%/55%
against the incumbent's 68%/78%**; same-arch, same-size, same-N, only the head and template
differ. Prime suspect is the **recent head shrink Q8_0 → Q3_K_S** (revision ~Sep 2026, saves
~0.5 GB VRAM); the discriminating test would be the superseded Q8_0-head revision or the
non-MTP sibling repo carrying Ornith's own template — not run, no reason to spend more on a
loser.

**Consequence: promoted anyway on 2026-10-17 (user decision).** The measured costs above are
accepted in exchange for the coding-specialist behaviour (Ornith-1.5 post-training), which
`llmbench` does not measure. `tiel-coder-35b` replaces the local `qwen3.6-35b` entry in
`llama-swap-nvidia.yaml` and `litellm-config.laptop.yaml` (no LiteLLM fallback wiring — the
fallback block stays commented out; it was scrubbed to reference tiel). The Qwen3.6-35B GGUF
was deleted. Do not re-litigate the speed trade without a new llama.cpp build: deep is
~40 vs qwen's ~46, prefill ~897 vs ~991, RSS 18.6 vs 19.4 GB, and draft acceptance 55% vs
78% is structural (base model + Sharp template, not the head — see the follow-up below).

**Follow-up: the draft head is NOT the problem, and the superseded Q8_0 head does not fit
(2026-10-17).** The pre-refresh revision (Q8_0 head + Sharp v22.4.0) was rebuilt *without*
re-downloading it — the head is a contiguous tail block, so a ~895 MB ranged fetch (24 MB
header + 870 MB tail) plus the current file's body reconstructs it byte-for-byte
(23,259,486,752 bytes; non-head body verified identical by aligned range hashes). Results:

| arm (`--spec-draft-n-max` / head) | accept s/d | tools | quality | note |
|---|---|---|---|---|
| n-max 2 / Q3_K_S (current) | 47-51%/55% | 4/4 | 4/4 | control |
| n-max 2 / **Q8_0** | 45-51%/**57%** | 4/4 | 4/4 | needs N=36 |
| **n-max 3** / Q8_0 | 39%/53% | 4/4 | 4/4 | worse |

- **Head precision is not the acceptance lever**: Q8_0 is +2 pts deep, inside noise. The
  23-pt gap to `qwen3.6-35b`'s 78% is the base model (Ornith-1.5 post-training) and/or the
  Sharp template, not the quant.
- **The Q8_0 head does not fit at N=35**: its block-40 experts are GPU-resident and cost
  ~460 MB more; the server loads but the first inference OOMs. It needs **N=36** — which is
  exactly why upstream re-quantized the head. Do not "fix" tiel by going back a revision.
- **`--spec-draft-n-max 3` loses acceptance again** (39%/53% vs 45-51%/57%), corroborating
  the earlier `n-max 3` finding. Keep 2.
- **Corrected clean numbers (2-model run, 4 rounds):** `tiel-coder-35b` (Q3_K_S, n-max 2)
  **deep 40.5 t/s** (40.5/38.7/40.6/41.2 — stable), prefill 897, acc 47%/55%, tools 4/4,
  quality 4/4; `lfm2.5-24b` same session: deep **48.0**, prefill 1932. Tiel loses to LFM2.5
  on every axis (16% deep, half the prefill, 2.2x the RSS) and verifies drafts at 55% against
  the incumbent's 78%.
- **Vs `qwen3.6-35b` directly (2×22.7 GB, 45 GB working set — run was floor-limited):**
  tiel 28.0 deep vs qwen 26.6, so they are comparable *under that handicap*; with lfm's
  36 GB run showing tiel at 40.5 and qwen's own documented 46.3, the ordering is
  **qwen ≈ 46 > tiel ≈ 40 > (lfm 48 by a different mechanism)**. Tiel's only possible edge
  is coding quality, which `llmbench` does not measure — its measured costs are real:
  −15% deep vs qwen, −50% prefill and 2.2x RSS vs LFM2.5, and 55% vs 78% draft acceptance.
- **The earlier 3-way figures were invalidated by two unrelated interference sources:**
  (a) a runaway `python3` worker in `whisper_server` (`whisper-pro-asr:full`) at 316-381% CPU
  and ~200 MB/s of reads — plain `podman stop` does not stick there, `restart: unless-stopped`
  relaunches it; (b) **interleaving three ~20 GB GGUFs** on this 62 GB box with zram 8/8 full —
  every swap re-reads 13-23 GB and kernel reclaim throttles the decode that follows. Under
  (b), *every* model read 15-27 t/s deep, including the recipe-benchmarked incumbent; the same
  configs read 40-48 t/s as a 2-model run. **Rule: bench at most 2 large models at a time
  here, and check `loadavg` + zram first.** It is not CPU throttling: P-cores boost to
  4.6-5.1 GHz under load and a single 700-token generation sustained 39.6 t/s.

## Running 26B/35B models on an 8GB card

Both large models are MoE, and ~90% of their weights are expert tensors any given token
never touches. `--n-cpu-moe N` keeps the expert tensors of the first N layers in system
RAM while attention, embeddings, norms and KV stay on the GPU. It composes with
`--n-gpu-layers 99` (ngl places layers, `--n-cpu-moe` overrides for expert tensors only)
and does nothing on dense models.

| model | layers | experts | quant | N |
|---|---|---|---|---|
| `tiel-coder-35b` | 40 | 256 / 8 active | **UD-**Q4_K_XL body + **Q3_K_S** head (22.75 GB) | **35** |
| `lfm2.5-24b` | 40 | 64 / 4 active | QAD-Q4_0 (13.58 GB) | **24** |
| `gemma-4-26b` *(retired)* | 30 | 128 / 8 active | UD-Q4_K_M (16.9 GB) + MTP head | **30** |

**`lfm2.5-24b` is the only N measured per-layer: ~322 MiB of expert per layer** (N=26 → 6634
MiB, N=24 → 7278 MiB). Use that ratio to size any future MoE on this card; the other rows'
`N` values were tuned empirically and never converted to MiB.

**The `N` column is the 8GB laptop's value and belongs to this section only.** On the
24GB desktop the same model runs **no `--n-cpu-moe` at all** — every layer left on the CPU
there costs ~40% of decode. See *Qwen3.6-35B-A3B on 7900 XTX 24GB*.

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

**`gemma-4-26b` (now retired) needed the same treatment and it was not optional.** At 128K/N=30/ub2048 it
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

`gemma-4-26b` (retired) was later measured properly (see below) and the propagated flags held up:
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
| gemma-4-26b *(retired)* | 2816 | `gemma-4-26b-mmproj-F16.gguf` |
| gemma-4-12b *(retired)* | 3840 | `gemma-4-12b-mmproj-F16.gguf` |
| gemma-4-e4b | — | `gemma-4-e4b-qat-mmproj-F16.gguf` (qat), `gemma-4-e4b-mmproj-F16.gguf` (non-qat) |

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

**Counter-example (2026-10-17): a model with no draft head at all now leads this card.**
`lfm2.5-24b` reaches **37.3 t/s deep** against `qwen3.6-35b`'s 34.6 *with MTP enabled* — see
[LFM2.5-24B-A2B on RTX 5070 8GB](#lfm25-24b-a2b-on-rtx-5070-8gb--promoted-config-2026-10-17).
MTP is the biggest win **available to a given model**, not a precondition for a fast tier.

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
   and no `--kv-unified` gives ~43K per slot, and Hermes pins `server-qwen3.8-27b` at `131072`
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
`server-qwen3.8-27b` beats the iGPU **33.6s vs 2m05.8s**, because subagent cost is prefill-dominated
and that is where the iGPU is weakest. A second tier is not an obvious win either.

## The tiny tier (Arc iGPU)

**`gemma-4-e2b` serves background tasks** — Q4_K_M, 64K, `--ubatch-size
2048`, **`f16` KV**, **no MTP**, `--reasoning off`. It is the only vision model on this tier
and the fallback for `server-qwen3.8-27b` vision requests.

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

The old table (6.5K → 558 t/s, 19K → 252, 50K → **485s to ingest**) was `qwen3.5-2b` (retired) on an
old build. `gemma-4-e2b` today: **53,567-token needle prefilled at 464 t/s in 115s**, found.
Still slower than the dGPU, but "485s to ingest 50K" is no longer the right mental model.

### Vision lives HERE now — the old "no vision" note was inverted

This section previously said *"Vision is absent because `local-vision` resolves to the
dGPU's far better model. The tier correctly rejects images."* **Both halves are now wrong.**
Since 2026-08-06 the dGPU runs `--no-mmproj` and **`server-qwen3.8-27b` falls back to
`gemma-4-e2b` on this tier** — with `gemma-4-e4b` as its fallback (removed 2026-08-06).
Both carry projectors.

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
2. **Per-request `reasoning_effort` was being dropped by LiteLLM — fixed 2026-08-24.**
   Sent straight to llama-server it works (108 tokens, zero reasoning); through the
   gateway it was **silently dropped** by `drop_params: true` (310 tokens, full reasoning,
   no warning). The cause was a missing `allowed_openai_params: ["reasoning_effort"]`, not
   a LiteLLM limitation — see [LiteLLM](#litellm). On *this* tier reasoning is still off at
   the server and the allowlist is deliberately **not** applied (see that section for why),
   so the conclusion below is unchanged for `gemma-4-e2b`.
3. **Unsloth's docs are wrong** about the Qwen3.5 Small series defaulting to reasoning off.
4. **`presence_penalty` 1.5-2.0 (Unsloth's recommendation) destabilises short factual
   output.** At temp 0.7 + pp 1.5 a 2B answered "17 times 4" as **56**; at temp 0, 68.
   The config uses 0.5.

**`--reasoning off` is a correctness requirement, not a speed tweak** — `gemma-4-e2b` backs
Hermes' `_smart_approve`, which sends `max_tokens=16` and expects one word. A thinking model
spends the whole budget reasoning and returns empty.

Caveat: `--reasoning off` removes reasoning waste, not verbosity. A vague prompt still
rambles to the cap; a well-specified one ("Reply with ONLY the title") answers in ~8 tokens.

**Re-proposed for the dGPU on 2026-08-09, rejected then, and now viable (2026-08-24).**
The pitch: subagent work (grep, read a file, decide yes/no) does not need a reasoning
trace, so let the child run without one. Both original mechanisms were bad — a second
llama-swap entry at `--reasoning-budget 0` (**point 1**: measured *worse* than thinking
on, trace leaks into `content`), or per-request params (**point 2**: silently dropped by
LiteLLM). Point 2 is now fixed by `allowed_openai_params` (see [LiteLLM](#litellm)), and
the right mechanism turns out to be neither of those: **top-level `reasoning_effort:
"none"`**, which llama.cpp handles by setting `enable_thinking = false` and erasing the
template kwarg (`tools/server/server-common.cpp`) — a real off switch with none of
`--reasoning-budget 0`'s leakage.

Crucially it costs **nothing**: same model, same instance, no swap. The old blocker was
that any "different reasoning config" meant a second llama-swap entry and a full
**22.66 GB no-mmap reload** on every orchestrator↔subagent switch. A request field has no
such cost. This is what `auxiliary.approval.reasoning_effort: none` now exploits — see
[Hermes wiring](#hermes-wiring-hermesconfigyaml).

`--chat-template-kwargs '{"enable_thinking":false}'` remains an untested alternative and
is no longer worth testing: it needs a second entry, and the request field does not.

## Embeddings

`embeddinggemma-2` = `embeddinggemma-2-Q8_0.gguf`, embedded Gemma 2 architecture, `--pooling mean`, ctx 8192.

- **`--pooling mean`.** The embeddinggemma-2 model uses mean pooling over token embeddings.
- **`--ubatch-size` must be ≥ the longest input.** With pooling the whole sequence must fit
  one ubatch, so it is pinned to `--ctx-size` (8192).

**Embeddings only** — this server cannot serve `/v1/chat/completions`.

## Per-device notes

**Intel iGPU (Arc)** — SYCL via the upstream-tracking `:intel` image. `gemma-4-e2b` and
`embeddinggemma-2` are pinned resident via `groups:` with `swap: false`, because they back
**both** background tasks and `server-qwen3.8-27b` vision fallback — a title request and an
image request must not evict each other. ~3.5 GB each.

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

**Intel NPU — whisper ASR now, not an LLM.** The experimental `intel_npu_llama_cpp` profile
and its OpenVINO `llama-server` (`Qwen3-1.7B`, 0.61 t/s decode, port 8083) are **gone**.
Port 8083 now serves `whisper-small-int4` through `whisper-pro-asr` for local STT. The
build recipe that used to live here is no longer used.

- **The NPU runs dynamic IRs; the app's gate is wrong.** whisper-pro-asr refuses the NPU
  unless the OpenVINO IR has static input shapes, and *every* optimum Whisper export is
  dynamic — so out of the box it silently decodes on the CPU. On OpenVINO 2026.3.1 the NPU
  executes those IRs fine (verified directly with `WhisperPipeline`, not just the probe), so
  the service sets `VERIFY_RUNTIME=false` to skip the gate (`ASR_DEVICE=NPU` pins the
  device). That flag only skips the probe, the NPU warm-up, and a startup ONNX-diagnostics
  log — and it also disables the safety check, so if a future model/driver breaks on the NPU
  there is no automatic CPU fallback.
- **Model choice: `whisper-small-int4`** (`anubhav200/openai-whisper-small-openvino-int4`),
  mounted read-only from `$LLAMA_MODELS_DIR/whisper-small-int4-ov`. Measured on a 60 s clip
  in one session: small-int4 NPU 4.8 s, large-v3-turbo NPU 8.2 s (and turbo needed a ~179 s
  NPU compile vs ~21 s). Turbo on the iGPU is faster still (4.4 s) and far more accurate —
  small-int4 trades accuracy for the NPU.
- **`MODEL_IDLE_TIMEOUT=0` keeps it resident.** The default 300 s unloads the model after
  five idle minutes, and the NPU **recompiles on every reload** (the compiled blob is never
  cached — the ASR pipeline is built with no `cache_dir`; the banner's "Binary Cache Status"
  is a false positive off the `temp/` dir). With 0 it stays in NPU memory for the container's
  life; only an actual recreate pays the ~21 s compile again.

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

Direct model names only.

> **Stale on the desktop as of 2026-10-17.** Every `server-qwen3.8-27b` reference in this
> section now needs to be `qwen3.8-flash-next` (desktop, 131072 pin unchanged). The edits
> live in `~/.hermes/config.yaml` and `~/.config/opencode/opencode.json`, outside this
> repo, and are part of the deferred laptop rewiring — see
> [Strata on the desktop](#strata-on-the-desktop--promoted-2026-10-17).

- `model.default: server-qwen3.8-27b`, `delegation.model: server-qwen3.8-27b`.
- `custom_providers[0].models.*.context_length` must be pinned. Without it Hermes reads
  `*.context_length` from GGUF metadata and advertises the native window (256K), overrunning
  the actual `--ctx-size` KV allocation.

| model | pin | why |
|---|---|---|
| `qwen3.8-flash-next` (was `server-qwen3.8-27b`) | **131072** | desktop, 131K ctx. `gemma-4-e2b` fallback only has 64K — an overflow there is a clean rejection, not a blind description |
| `gemma-4-e2b` | **65536** | laptop iGPU, 64K. Raising this overruns the iGPU. The tier ingests 53K in ~115s at 464 t/s — usable, but still ~2.5x slower than the dGPU |

**The 131072 pin carries over unchanged.** Strata serves the desktop at `CONTEXT=131072`,
so the pin stays correct across the engine swap; only the name changes.

**`delegation.max_concurrent_children: 3` is currently aspirational (2026-08-09).** Every
llama-server here is `--parallel 1`, and on `server-qwen3.8-27b` that is forced by MTP, so
children serialize regardless of what this value says. It is not harmful — Hermes queues —
but do not read it as evidence that three children run concurrently. See
[Parallel subagents](#parallel-subagents--analysed-not-measured-2026-08-09) for what it
would cost to make it true.
- `auxiliary.<task>.{provider,model,base_url,api_key,timeout}` — `base_url` set explicitly
  on every one so they cannot silently fall back to openrouter.

**Reasoning effort is a Hermes-side knob (2026-08-24).** Hermes' bundled `custom` provider
profile (`plugins/model-providers/custom/__init__.py`) emits **top-level
`reasoning_effort`** on every request to a `provider: custom` endpoint — it always has, and
the gateway was dropping it. Now that it lands, the live settings are:

| key | value | why |
|---|---|---|
| `agent.reasoning_effort` | `medium` | floor for anything without an override |
| `agent.reasoning_overrides.server-qwen3.8-27b` | `xhigh` | main turn gets the deep tier |
| `auxiliary.approval.reasoning_effort` | `none` | `max_tokens=16` must not go to reasoning |
| `auxiliary.title_generation.reasoning_effort` | `none` | one-line output, no trace needed |
| `auxiliary.compression.reasoning_effort` | `low` | on the critical path, mid-turn |

`agent.reasoning_effort` is documented upstream as "OpenRouter and Nous Portal" — that
comment is stale for `provider: custom`, which routes through the profile above instead.
Levels are limited to `xhigh`/`medium`/`low`/`none` by Qwen3.8's template even though
Hermes' `VALID_REASONING_EFFORTS` accepts `minimal`/`high`/`max`/`ultra` too.

Auxiliary tasks split on **critical path vs background**, not prompt size:

| tier | tasks |
|---|---|
| `server-qwen3.8-27b` | `compression`, `web_extract`, `kanban_decomposer`, `profile_describer`, `curator`, `monitor`, `memory_query_rewrite`, `triage_specifier`, `goal_judge` |
| `gemma-4-e4b` (laptop dGPU) | `mcp`, `skills_hub`, `approval`* |
| `gemma-4-e2b` | `title_generation`, `tts_audio_tags` |

\*These three moved from the retired `ornith-1.5-9b` to `gemma-4-e4b` on 2026-10-17 (see
[Direct naming](#direct-naming-2026-08-25)). `approval` is pinned to `reasoning_effort: none`
per request, which is what makes it safe, and `gemma-4-e4b`'s LiteLLM entry now carries
`allowed_openai_params: ["reasoning_effort"]` — without that allowlist the param is dropped
and the `max_tokens=16` shape returns **empty** (measured). With it: `APPROVE`, `finish: stop`,
3 tokens.

Anything the user waits on goes to `server-qwen3.8-27b` — it is faster *and* reuses the
loaded model. Fire-and-forget goes to the iGPU so it does **not** evict the large model.
Timeouts are well above Hermes' defaults because a timeout mid-compression drops context.

**Delegation runs on `server-qwen3.8-27b`, measured not assumed:** 33.6s vs 2m05.8s on the
iGPU. During synchronous delegation the parent is idle so the primary GPU is free anyway
and the child reuses the loaded model; each instance is `--parallel 1` so concurrent
children serialize either way; and subagent cost is prefill-dominated, where the iGPU is
weakest. The iGPU only wins for `background=true` delegation.

**`approval` MUST stay on a non-thinking model — correctness, not preference.**
`tools/approval.py::_smart_approve` sends `max_tokens=16, temperature=0` and expects one
word. On a thinking model the whole budget goes to reasoning:

| tier | result |
|---|---|
| `server-qwen3.8-27b` (thinking on) | `finish=length`, 64 chars reasoning, **content `''`** |
| `gemma-4-e2b` (`--reasoning off`) | `finish=stop`, 0 reasoning, **`APPROVE`** |

Smart approval was silently broken while it pointed at `server-qwen3.8-27b`, then kept there
by operator decision (2026-08-17). **Resolved 2026-08-24 without moving the task:**
`auxiliary.approval.reasoning_effort: none` makes the request itself non-thinking
(`enable_thinking = false` at llama-server), so `max_tokens=16` is spent on the answer.
`server-qwen3.8-27b` may now stay as the approval tier. The old rule — *never point `approval`
at a thinking model* — is superseded by *never point it at a thinking **request***; the
tier no longer matters, the effort does. Caveat unchanged: `_smart_approve` would not fire
from a `hermes -z` one-shot even with a flagged command — verify interactively, watching
`podman logs llama_swap_intel | grep -c "POST /v1/chat/completions"`.

**`memory_query_rewrite` almost certainly never fires** — only external memory providers
reference it, and `memory.provider` is empty.

**`auxiliary.web_extract` is misleadingly named.** It does not control the `web_extract`
tool (`tools/web_tools.py` makes no LLM call — it truncates at 15000 chars). It is consumed
by `tools/browser_tool.py` for browser *snapshots*, gated on
`len(snapshot_text) > 15000 and user_task`. In three realistic attempts it never fired
once. Verify with request counts before concluding a change to it did anything.

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

**OpenCode sets reasoning effort via model/agent `options` — the key is
`reasoningEffort`, camelCase (2026-08-24).** `provider.custom.models.<id>.options` and
`agent.<name>.options` both work; the AI SDK translates `reasoningEffort` into the
top-level `reasoning_effort` body field.

**Snake_case is silently dropped.** `"options": {"reasoning_effort": "medium"}` produces
a request with no effort field at all — no error, no warning, and the model just runs at
the server default. Verified on 1.18.21 by proxying opencode through a logging forwarder:
`reasoning_effort` → absent, `reasoningEffort` → `"reasoning_effort":"medium"` on the wire.
Neither `models.<id>.request.body` nor a provider-level `options.extraBody` reaches the
body either — `options.reasoningEffort` is the only shape that works.

Agent-level overrides the model-level default, which is what replaced the old
`-xhigh`/`-low` model entries: `agent.plan.options.reasoningEffort: xhigh`,
`agent.build.options.reasoningEffort: medium`, model default `medium`. A `plan` turn
sends two requests — `xhigh` for the turn itself and `medium` for the secondary
title/summary call, which uses the model-level value. That is expected, not a bug.

The provider id must not contain a dot: the SDK derives its providerOptions key with
`provider.split(".")[0]`, so a dotted id silently drops every option
(anomalyco/opencode#23622). `custom` is fine.

**Ctrl-T cycles effort through model `variants` (2026-08-24).** `variant_cycle` is bound to
`ctrl+t` ("Cycle model variants") by default. `server-qwen3.8-27b` defines three:

```json
"variants": {
  "low":    { "reasoningEffort": "low"    },
  "medium": { "reasoningEffort": "medium" },
  "xhigh":  { "reasoningEffort": "xhigh"  }
}
```

A variant object **is** an options bag, and it is merged **last**:
`base → model.options → agent.options → variants[selected]`. So a variant always wins over
both the model default and the agent override — no need to strip the agent settings.

Cycle order is `Object.keys(variants)` then back to unset: **unset → low → medium → xhigh →
unset**. Unset is not "no effort" — it falls through to `model.options.reasoningEffort`
(`medium`), so `medium` appears twice in the cycle. Harmless; renaming or dropping the
`medium` variant removes the duplicate if it annoys. A variant named `default` is treated
specially by the picker (filtered from labels) — don't use that name.

Variants also appear in the model picker as `custom/server-qwen3.8-27b/<variant>`, but
**`opencode run -m` does not accept that suffix** — it fails with `UnknownError` /
`err_db0207f2`. Variant selection is TUI-only; for headless runs use `--agent` (or an agent
with both `model` and `variant` set, though that combination hung in testing and is not
recommended).

**Small models are deliberately absent from `opencode.json` (2026-08-24).** `gemma-4-e2b`
was removed from the opencode picker only — it remains live in `llama-swap-intel.yaml`, in
`litellm-config.laptop.yaml`, and as the `gemma-4-e2b` model entry for Hermes'
`title_generation` / `tts_audio_tags`. Do not "tidy up" the iGPU tier to match opencode;
the two are intentionally different.

**Declared output caps follow one rule (2026-08-17):** `model_info.max_output_tokens` in the
LiteLLM configs (`litellm-config.laptop.yaml`, `litellm-config.desktop.yaml`) and
`limit.output` in `opencode.json` are **32K (32768) for models with a 128K window, 16K
(16384) for models with a 64K window**. Apply it to any new entry. The per-request cap
Hermes sends is separate and currently unpinned.

**Fallbacks cannot absorb a context overflow.** The same log shows LiteLLM failing over to
`gemma-4-26b` (since retired), which was also 64K, and failing identically. Every local model shares one
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
- **Fallbacks match the name as *requested*, not resolved.** `server-qwen3.8-27b` does not
  inherit a fallback declared for `qwen3.6-35b` — it fails with `No fallback model group
  found for original model_group=server-qwen3.8-27b`. Every model group needs its own entry.
- **Do not list one machine's models in the other's config.** The laptop once carried the
  desktop's entries pointing at an unreachable host; once the laptop gained its own
  `gemma-4-26b` (since retired) that became a duplicate `model_name` and LiteLLM would have load-balanced
  across a live and a dead endpoint.
- **The server-side LiteLLM is in-repo and live — edit it here (2026-10-17).**
  `llama-cpp.yml` runs it as `litellm_server` (profile `server`, published :4000 →
  chat.gusev.tech) mounting **`litellm-config.desktop.yaml`**, which now fronts `strata`
  and exposes exactly one local model, `qwen3.8-flash-next`. The old
  `litellm-config.server.yaml` (and its `qwen3.8-27b`/`qwen3.6-35b` entries plus the
  non-dotted `model_group_alias` pair) was **deleted 2026-10-17**. `litellm-config.desktop.yaml`
  is the live desktop config now — the old note calling it legacy is superseded.
- **`reasoning_effort` needs `allowed_openai_params` — `drop_params: true` eats it
  otherwise (2026-08-24).** For an unrecognised `openai/*` model LiteLLM raises
  `UnsupportedParamsError`, and `drop_params: true` converts that into a **silent** drop:
  no warning, no log line, just a full-reasoning response. Adding
  `allowed_openai_params: ["reasoning_effort"]` to a model's `litellm_params` forwards it
  verbatim — LiteLLM does no normalization on the value, so `xhigh` survives (unlike
  Bifrost). **Both hops must allowlist it**: a laptop request to `server-qwen3.8-27b`
  crosses the laptop's LiteLLM *and* the desktop's, and either one dropping it loses the
  param. Deliberately **not** applied to `gemma-4-e2b` — it runs
  `--reasoning off` as a correctness requirement, and Hermes sends `reasoning_effort` on
  every request, so the drop there is load-bearing. **Same deliberate drop for `lfm2.5-24b`**
  (2026-10-17): LFM2.5's template defines no effort vocabulary, so allowlisting it would
  forward an off-vocabulary value to the server and only risk an error.

### Remote outage handling — how the gateway fails over to local (2026-08-25)

**Superseded 2026-10-16: busy now means *wait*, not fail over.** Fallbacks are commented
out and the requirement became "client waits until the server model finishes". The
desktop's llama.cpp (`--parallel 1`) queues FIFO while a slot is occupied, so the remote
entries now run `timeout`/`stream_timeout: 900` + `keepalive_seconds: 15` (SSE pings keep
the connection live through the silent queue wait), `cooldown_time: 0` with
`allowed_fails_policy` removed — the old first-timeout-300s-cooldown was producing the
useless `429 all_deployments_in_cooldown` the clients actually saw. Router-wide
`retry_after: 15` spaces the 3 retries that remain (transient 502s now wait instead of
bursting). `TimeoutErrorRetries: 0` stays: a litellm timeout disconnects the upstream,
llama.cpp aborts the disconnected generation, so a retry would restart it from zero.
Desktop side: `request_timeout` 600→960 so the laptop is always the one that gives up,
and `TimeoutErrorRetries: 0` added for both Qwen groups so its `num_retries: 3` cannot
re-send cancelled work. Accepted trade-off: busy and down are indistinguishable from the
client (both are silence), so a powered-off desktop now surfaces only after ~900s instead
of ~180s. Everything below stays as the 2026-08-25 fail-fast design and documents the
LiteLLM 1.99.0 cooldown quirks (`_is_cooldown_required`, per-deployment
`model_info.allowed_fails_policy`), which are still true.

The laptop routes `server-qwen3.8-27b` through the desktop's LiteLLM at
`https://chat.gusev.tech/v1`. When the desktop is off (TCP blackhole — the dominant
failure shape for a powered-off machine with a DynDNS IP), the old behavior was to hang
for ~30 minutes before falling back to local `qwen3.6-35b`. Root cause: `request_timeout:
600` × (`num_retries: 3` + initial attempt) = up to 40 min per request, and LiteLLM's
cooldown mechanism was entirely disabled for this topology.

**Why cooldown was disabled.** In LiteLLM 1.99.0 (the running build), `_is_cooldown_required`
in `router_utils/cooldown_handlers.py` returns `False` for any exception whose string
contains `"APIConnectionError"` — the common shape for connection-refused/DNS failures.
For the dominant blackhole shape (`httpx.ConnectTimeout` → openai `APITimeoutError` →
litellm `Timeout`, status 408), cooldown *is* possible, but the per-group `allowed_fails`
setting only works for multi-deployment groups. Single-deployment groups (like each remote
entry) are exempted by a safety net: a plain int `allowed_fails` is ignored, and only an
explicit per-exception-type `model_info.allowed_fails_policy` overrides it.

**The fix, verified against the running build:**

- Per-deployment `litellm_params.timeout` and `litellm_params.stream_timeout` override the
  global `request_timeout: 600`. Both keys are required because agents use the streaming
  path (`_get_stream_timeout` reads only `stream_timeout`, never `timeout`).
- Per-deployment `model_info.cooldown_time` and `model_info.allowed_fails_policy` with
  `TimeoutErrorAllowedFails: 0` cause the first timeout failure to immediately cool the
  deployment for 300 seconds. During cooldown, deployment selection raises
  `RouterRateLimitError`, which `async_function_with_fallbacks` catches — instant fallback
  to `qwen3.6-35b`, zero extra wait.
- `model_group_retry_policy` with `TimeoutErrorRetries: 0` prevents any retry on timeout
  errors for the remote groups, so the first request in an outage costs exactly one 180s
  attempt before falling back.

**`timeout: 180` covers any legitimate warm desktop turn.** Desktop prefill is 743 t/s;
at 180s that is ~133K tokens — exceeds the 131K window. Entries are `ttl: 0` (resident),
so cold loads are only from cross-model switches (~18s overhead). 180s is the ceiling
that eliminates false-positives while cutting outage detection from ~30 min to ~3 min.

**`cooldown_time: 300` means one wasted 180s probe per ~5 min during a sustained outage.**
After 300 seconds the router re-tests the remote; if still dead, another 180s attempt and
a fresh cooldown cycle begins.

**Resulting behavior:**

| scenario | before | after |
|---|---|---|
| remote healthy | baseline | unchanged (180s ≫ normal TTFB) |
| first request in outage | ~30 min dead time | ~180s → immediate fallback to `qwen3.6-35b` |
| subsequent requests within 300s | full 30-min chain **again** | **instant** fallback, zero wait |
| recovery | — | after 300s one probe re-tests remote; still down ⇒ another ~180s + fresh cooldown |

**Known residual: connection-refused/DNS shape.** If the host fails fast (SYN refused or
NXDOMAIN), LiteLLM raises `APIConnectionError`, which this build refuses to cool down and
has no `model_group_retry_policy` field for. Each request then costs up to 4 × 180s ≈ 12
min with no learning. The realistic "desktop is off" shape is the blackhole-timeout case
above; fixing this would require weakening local-model retry behavior, which isn't worth
it.

**Background health checks (`health_check_interval` + `enable_health_check_routing`) were
evaluated and rejected.** In a single-deployment group the "all candidates unhealthy →
bypass filter" safety net sends traffic back to the dead endpoint anyway. Probes also cost
real completions that would evict/pin resident local models.

**Global `request_timeout: 600` and `num_retries: 3` are untouched.** They are needed for
local llama-swap cold loads, vision prefill, and swap-in time. The remote-group changes
only affect the two remote entries.

## Operational gotchas

- **502 `proxy error: EOF` right after a stream = llama-swap reusing a connection
  llama-server already closed.** llama-swap pools idle upstream keep-alive sockets;
  llama-server advertises keep-alive on streamed responses and then closes them anyway,
  so the next request lands on the dead socket and 502s. Reads like "model is busy"
  because it fires during back-to-back streaming jobs (a 118-chunk run failing at
  chunk 52). Fix landed 2026-10-16: `disableKeepAlives: true` on **every** model in every
  `llama-swap*` config — one fresh TCP connect per request, <1 ms on localhost.
  Per-model key only; there is no global switch (verified against llama-swap
  `config-schema.json`).

- **Episodic `400 Invalid model name passed in model=<name>\x00\x00...` (2026-08-24).**
  The desktop's LiteLLM intermittently rejects a model name that arrives NUL-padded.
  Confirmed to be LiteLLM's own error (`proxy/route_llm_request.py:152`,
  `ProxyModelNotFoundError`) — the string exists in neither llama-swap nor llama-server,
  so the padded name really does reach LiteLLM's router.

  **It comes in bursts, not at a steady rate.** Measured the same request repeatedly
  against `chat.gusev.tech`: one window gave 3/8 failures, a later window gave **0/40**.
  Do not conclude it is fixed from a clean run, and do not conclude a rate from a small
  sample — an early 8-request burst looked like an HTTP/1.1 correlation that a 20-per-
  protocol rerun completely erased.

  Ruled out: the laptop hop (reproduces calling the desktop directly); `model_group_alias`
  (the direct name `qwen3.8-27b` fails at the same rate as the alias `server-qwen3.8-27b`);
  config drift (`/v1/models` returns all four names clean and correctly sized); and
  HTTP/2 vs HTTP/1.1. A separate, possibly unrelated failure mode appears as client
  **timeouts** on the same endpoint, including on `server-qwen3.6-35b` — plausibly the
  24GB card cold-loading the other model, which is expected cost, not a fault.

  **Retrying the identical request has always succeeded.** `num_retries: 3` does not cover
  it because a 400 is not a retryable status; `litellm_settings.retry_policy.
  BadRequestErrorRetries: 2` would (the field exists in this build). That is a mitigation
  with a real cost — genuinely malformed requests get retried too — so it is a deliberate
  choice, not an obvious win.

  **Not yet root-caused.** The deciding evidence is on the desktop and was never captured:
  `podman logs litellm_server` around a failure. If the name arrives padded it is Caddy's
  `reverse_proxy`; if it arrives clean the corruption is inside LiteLLM.

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
  looks like a mystery failure under agentic churn. **300** is the safe value — already set
  in `llama-swap-nvidia.yaml` and `llama-swap-intel.yaml`; the old
  `llama-swap-server.yml` recommendation died with the file on 2026-10-17. Raise it before
  running any benchmark sweep — it is a confound in every cold-load measurement.

### Strata (desktop) gotchas

- **`ulimits.memlock: -1` is mandatory.** The engine page-locks the expert arena; without
  it the container fails at startup. Verify: `podman inspect strata --format
  '{{.HostConfig.Ulimits}}'`.
- **`stop_grace_period: 90s`, not the repo default 5s.** Releasing a page-locked arena on
  SIGTERM regularly exceeds 10s (upstream documents `docker stop -t 60`), and a SIGKILL
  mid-release leaves the arena to the OOM reaper.
- **First start is minutes of silence, not a hang.** The setup pass unpacks the pack,
  fetches the MTP draft and loads the arena before :8080 opens; the image's healthcheck
  carries `--start-period=600s` for that reason. Watch `podman logs -f strata`.
- **`STRATA_ARENA_PIN_GIB=40` of 96GB is the desktop's whole memory contract.** The arena
  is page-locked *and* the desktop is a daily driver — raising the pin trades desktop
  responsiveness for expert-cache hits, and there is no zram-style safety net for pinned
  pages.
- **The models dir is mounted writable on purpose.** Strata writes `<shard>.done` checksum
  markers next to the GGUFs; `:ro` breaks first-boot verification. Every llama-swap mount
  in this repo is `:ro`/`:z,ro` — do not "fix" this one to match.
- **podman is undocumented upstream.** Strata's docs assume Docker + nvidia-container-toolkit
  and never mention podman. `base_nvidia`'s `deploy.resources.reservations` is what this
  repo uses for `nvidia_llama_swap`, so it is the first thing to trust — and the first
  thing to replace with `nvidia-ctk cdi generate` + `--device nvidia.com/gpu=all` if the
  container starts without a GPU.
- **The container is CUDA-only.** There is no ROCm path in the image, and a mixed
  HIP+CUDA run is unsupported upstream — do not try to bring the 7900 XTX in.

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

On the **desktop**, **Strata** is on host port **8080** (there is no llama-swap there), so
`smoke.py`'s tier probe reports the primary GPU unreachable. Either edit `TIERS` at the top
of `smoke.py`, or use `llmbench.py --endpoint http://localhost:8080/v1`. The gateway checks
are unaffected — LiteLLM is on 4000 on both machines, and going through the gateway is the
better test anyway.

**No Strata numbers exist yet.** Every performance figure in this file is llama.cpp, on the
laptop. The desktop's Strata tier has not been benchmarked — there was nothing to measure
against, since the migration was delivered without a running deployment. First measurements
belong here when they happen.

### When to run what

```bash
./smoke.py                    # after ANY config edit, container restart, or model swap
./smoke.py --quick            # just show what is loaded where (no generation)

./llmbench.py --models tiel-coder-35b gemma-4-e4b --tests perf --rounds 3
./llmbench.py --models tiel-coder-35b gemma-4-e4b --tests all   # before promoting a config
./llmbench.py --models qwen3.8-flash-next --fail-on-regression  # CI gate
```

`smoke.py` is the gate after any change to this repo. It replays the exact `max_tokens=16`
approval shape and flags empty-content responses — that is how the smart-approval breakage
was found, and it is the one failure mode a "does it respond" check misses.

`llmbench.py --tests all` is what a config must pass **before being promoted** into the main
tier: `tools` 4/4, `quality` no worse than the incumbent, and `vision` passing on a real
image. On the desktop, the equivalent gate runs against `qwen3.8-flash-next` — and note
`smoke.py`/`llmbench.py` speak OpenAI, so they need `--endpoint http://localhost:8080/v1`
(there is no llama-swap `/api/models/unload` endpoint to free the GPU with; Strata is
resident by design).

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
- **Keep a run's summed GGUF footprint ≤ ~40 GB** on this laptop (62 GB RAM, zram 8/8 full).
  Three ~20 GB models (59 GB) read 15-27 t/s deep; **two 22.7 GB 35Bs (45 GB) already
  depressed** tiel/qwen to 28/27 t/s; the same tiel read **40.5** against 13.6 GB LFM2.5
  (36 GB total). Every large-fileset run re-reads 13-23 GB per swap and kernel reclaim
  throttles the decode that follows. Check `cut -d' ' -f1 /proc/loadavg` and `free -h`
  first, and remember `whisper_server` can run away at 300%+ CPU — see the Tiel entry above.
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
