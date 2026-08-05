# AGENTS.md — llama.cpp / llama-swap / LiteLLM stack

Operational notes for working on this AI inference stack. These capture non-obvious gotchas
learned the hard way — read before editing any `llama-swap-*.yaml`, either `litellm-config.*.yaml`,
or adding models. For "how do I run this", see `README.md`.

## Architecture

Two machines. Each llama-swap instance mounts exactly one config and therefore advertises only
models its device can actually run:

| config | instance | device | host port | models |
|---|---|---|---|---|
| `llama-swap-config.yaml` | `llama_swap_server` | 7900 XTX 24GB (desktop) | 8081 | `gemma-4-12b`, `gemma-4-26b`, `qwen3.6-27b`, `qwen3.6-35b`, `qwen3-coder-30b` (+ an unused 8GB-tier section kept so the file works standalone) |
| `llama-swap-nvidia.yaml` | `llama_swap_nvidia` | RTX 5070 8GB (laptop) | 8081 | `qwen3.6-35b` (default), `gemma-4-26b`, `qwen3.5-9b` |
| `llama-swap-intel.yaml` | `llama_swap_intel` | Arc Pro iGPU (laptop) | 8082 | `qwen3.5-2b` (text-only, non-thinking), `embed` |

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

### Measured performance (laptop, 6524-token prefill + 700-token generation)

All numbers below are same-session. Absolute values drift 20-30% with load and thermals — an
earlier run had `gemma-4-26b` at 641 tok/s prefill, a later one 467 — so **only ever compare models
measured in the same session.** The ratios have been stable across every repetition.

> **Decode is two different numbers, and this table's old figures were the pessimistic one.**
> `ai/bench/llmbench.py` reports `decode` (generation from a fresh short prompt, ~0 context —
> the `tg128`-equivalent that most online figures mean) and `deep` (generation continuing from
> the ~6.5K prefill, which is what an agent turn actually does). **Quote `deep` when judging an
> agent tier.** The `qwen3.6-35b` row below said **14.9 tok/s** for a long time; re-measured on
> the *unchanged* config it is **29.3 deep / 33.5 shallow** with prefill unchanged, so the old
> number was a hand-measured deep figure taken before `ai/bench/` existed and was never
> comparable to anything since. Rows not marked "re-measured" may have the same problem.

| tier | model | prefill | decode (deep) | VRAM |
|---|---|---|---|---|
| RTX 5070 | `qwen3.6-35b` **(default)**, tuned 2026-08-05 | 411-454 tok/s | **31.4 tok/s** (36.6 shallow) | 6947 MiB |
| RTX 5070 | ^ before tuning (Q4_K_XL, default threads) | 425 tok/s | 29.3 tok/s (33.5 shallow) | 7103 MiB |
| RTX 5070 | `gemma-4-26b` (alternative) | **616 tok/s** | 17.9 tok/s *(stale, pre-`deep`)* | 6903 MiB |
| RTX 5070 | `qwen3.5-9b` | **1932 tok/s** | **48 tok/s** *(stale)* | 6303 MiB |
| Arc iGPU | `qwen3.5-2b` | **558 tok/s** | **23.1 tok/s** *(stale)* | 1.34 GB RAM |
| Arc iGPU | `embed` (Qwen3-Embedding-0.6B) | — | — | 0.80 GB RAM |
| Intel NPU | `Qwen3-1.7B` | 33 tok/s | **0.61 tok/s** | RAM |

**The default is deliberately not the fastest option.** `gemma-4-26b` beats `qwen3.6-35b` on both
axes (~1.6x prefill, ~1.2x decode) *and* uses less VRAM. `qwen3.6-35b` is the default anyway,
trading latency for a 35B-class model over a 26B. A trivial Hermes turn costs **~60s** on
`qwen3.6-35b` versus **~39s** on `gemma-4-26b` and **~2.6s** on `qwen3.5-9b`. If latency matters
more than model size, flip `local-main`/`local-vision` to `gemma-4-26b` in
`litellm-config.laptop.yaml` — nothing else has to change.

### Running 26B/35B models on an 8GB card: `--n-cpu-moe`

Both large models are Mixture-of-Experts, and in both ~90% of the weights are expert tensors that
any given token never touches. `--n-cpu-moe N` keeps the expert tensors of the first N layers in
system RAM while attention, embeddings, norms and the KV cache stay on the GPU. The dense parts
every token needs are on the GPU; the sparse parts it skips are in RAM.

| model | layers | experts | quant | tuned N | why that N |
|---|---|---|---|---|---|
| `qwen3.6-35b` | 40 | 256 / 8 active | UD-Q4_K_M (22.1 GB) | **34** | N buys ~nothing at depth (see below); 34 keeps ~1.2GB vision headroom |
| `gemma-4-26b` | 30 | 128 / 8 active | UD-Q4_K_XL (15.8 GiB) | **26** | leaves room for the projector + ~1.2GB headroom |

`--n-cpu-moe` composes with `--n-gpu-layers 99`: ngl decides layer placement, `--n-cpu-moe`
overrides it for expert tensors only. It does nothing on dense models like `qwen3.5-9b`.

Sweeps (lower N = more on GPU = faster, more VRAM):

```
qwen3.6-35b (Q4_K_XL)          gemma-4-26b (Q4_K_XL)
  N=36  14.2 t/s  6137 MiB       N=30  21.8 t/s  3621 MiB
  N=34  14.9 t/s  7103 MiB  <-   N=26  23.4 t/s  6883 MiB  <-
  N=33  16.4 t/s  7539 MiB       N=24  24.4 t/s  6529 MiB (no mmproj)
  N=32  VISION CRASHES           N=22  25.9 t/s  7435 MiB (no mmproj)
                                 N<=18 OOM at load
```

**Those decode figures are shallow (~0-context) numbers, and N does NOT buy deep decode.**
Re-measured on `UD-Q4_K_M` at `--threads 6`, sweeping N with everything else fixed:

| N | mmproj | prefill | decode (shallow) | deep (8.6K ctx) | VRAM |
|---|---|---|---|---|---|
| 34 | yes | 454 t/s | 37.2 t/s | **31.4 t/s** | 6985 MiB |
| 33 | yes | 461 t/s | 37.3 t/s | **31.8 t/s** | ~7452 MiB |
| 31 | **no** | 483 t/s | 38.8 t/s | **31.7 t/s** | ~6100 MiB |

Moving **three** expert layers from CPU to GPU changed deep decode by ~0.3 t/s — noise.
Shallow decode moved (37.2 -> 38.8) and prefill moved (454 -> 483), but the number an agent
turn actually experiences did not. The ~5.5 t/s shallow-to-deep gap is context-dependent
attention work on the GPU, and expert placement cannot touch it.

**So tune `--n-cpu-moe` for VRAM headroom and prefill, not for decode.** Since lower N buys
almost nothing at depth, prefer the *higher* N that keeps vision headroom — N=34 costs
~0.4 t/s against N=33 and buys 470 MiB of margin against the vision-crash boundary.

### CPU thread count for `--n-cpu-moe`: fewer, faster threads win

`--n-cpu-moe` puts ~92% of the weights on the CPU, so decode is gated by CPU expert
dequant+gather — which makes `--threads` a real tuning lever, and the default wrong. This is
a hybrid-core chip:

```
CPU 0-5    P-core   5400 MHz
CPU 6-13   E-core   4500 MHz
CPU 14-15  LP-E     2500 MHz   (SoC tile, ~half speed)
```

Measured on `qwen3.6-35b` UD-Q4_K_M, `--n-cpu-moe 34`, 8.6K prefill, interleaved rounds:

| `--threads` / affinity | prefill | decode | deep |
|---|---|---|---|
| unset (spawns 16) | 448 t/s | 34.2 t/s | 30.5 t/s |
| `14 --cpu-range 0-13 --cpu-strict 1` | 455 t/s | 25.0 t/s | 22.3 t/s |
| `12 --cpu-range 0-11 --cpu-strict 1` | 453 t/s | 25.0 t/s | 22.2 t/s |
| **`6 --cpu-range 0-5 --cpu-strict 1`** | 453 t/s | **36.9 t/s** | **31.6 t/s** |

**The obvious hypothesis is wrong.** "The two 2500 MHz LP-E cores gate llama.cpp's per-op
barrier, so exclude them" predicts `-t 14` wins. It loses badly — *worse* than leaving all 16
unpinned. Excluding only the LP-E cores is the second-worst configuration tested.

What actually holds is **fewer, faster threads**: 6 P-cores beat 16, while 12 and 14 are the
worst. The expert gather is dominated by per-op synchronisation, not by aggregate CPU
throughput, so adding mid-speed cores costs more in barrier overhead than they contribute.

**Prefill is unaffected** (448-455 t/s across every configuration) because it is GPU-bound —
only decode responds to thread placement. Do not tune this on a prefill number.

### Quant choice for CPU-offloaded MoE — it cuts both ways

`qwen3.6-35b` was originally `UD-IQ4_XS` (17.7 GB) and was re-benchmarked on `UD-Q4_K_XL`
(22.4 GB). Same session, each tuned to its own safe N:

| quant | N | prefill | decode |
|---|---|---|---|
| UD-IQ4_XS | 32 | **535 tok/s** | 10.0 tok/s |
| UD-Q4_K_XL | 34 | 395 tok/s | **14.9 tok/s** |

Decode improved **+49%**, prefill regressed **-22%**. Two independent effects:

- **Decode improves** because i-quant dequantization is markedly more expensive on CPU than
  K-quant, and `--n-cpu-moe` puts ~90% of the weights there. This is the predicted effect.
- **Prefill regresses** because the K-quant file is 26% larger, so two fewer expert layers fit on
  the GPU (N=34 vs 32). Prefill activates many experts across the batch, so it is far more
  sensitive to expert-layer placement than decode is.

Q4_K_XL wins whenever `prompt_tokens < ~50 x generated_tokens`. Thinking models emit hundreds of
reasoning tokens per turn, so typical agent turns land well inside that — a 6524-token prompt plus
a 700-token generation is 63.5s on Q4_K_XL versus 82.2s on IQ4_XS. Huge-prompt/terse-output
workloads would prefer IQ4_XS; that file is still on disk.

**The lesson: for CPU-offloaded MoE, prefer K-quants over i-quants — but re-tune `--n-cpu-moe`
afterwards and re-measure *both* axes.** A bigger file buys decode and costs prefill.

### Splitting the 35B across BOTH GPUs with Vulkan — tested, rejected (2026-08-05)

The intuition is compelling and will be proposed again, so here is the measurement that
killed it. **Idea:** `--n-cpu-moe` makes the *CPU* do the expert dequant+gather every token;
the laptop also has an Arc iGPU, so let the iGPU do that work instead.

**It is mechanically possible, and simpler than it sounds.** llama.cpp RPC is *not* needed —
a single Vulkan process drives both GPUs at once. Neither `:cuda` nor `:intel` ships
`rpc-server`, `libggml-rpc.so`, or a `--rpc` flag, so the RPC route would have meant building
both sides; `:vulkan` needs none of that:

```bash
podman run --rm --device /dev/dri --device nvidia.com/gpu=all \
  --security-opt label=disable --group-add 105 --group-add 39 \
  --entrypoint /app/llama-server ghcr.io/mostlygeek/llama-swap:vulkan --list-devices
#   Vulkan0: Intel(R) Graphics (ARL)          (47779 MiB, 30480 MiB free)
#   Vulkan1: NVIDIA GeForce RTX 5070 Laptop   (8151 MiB,  6718 MiB free)
```

**`--security-opt label=disable` is mandatory and non-obvious.** CDI injects the NVIDIA
Vulkan ICD at `/etc/vulkan/icd.d/`, but SELinux blocks the driver it points at, and the
failure is silent — only the Arc enumerates. The giveaway is
`Could not get 'vkCreateInstance' via 'vk_icdGetInstanceProcAddr' for /usr/lib64/libGLX_nvidia.so.0`.

`--tensor-split` is the **wrong tool** for a MoE: it divides *layers*, so it puts half the
attention and KV on the Arc. The MoE-correct split is the Arc standing in for the CPU:

```
-dev Vulkan1,Vulkan0 -sm layer -ts 1,0 -mg 0 -ngl 99 -ot 'ffn_.*_exps=Vulkan0'
```

`-sm none` does **not** work — it deactivates the Arc backend, and the load aborts with
`pre-allocated tensor (blk.0.ffn_down_exps.weight) in a buffer (Vulkan0) that cannot run the
operation (NONE)`. Both devices must stay active; `-ts 1,0` is what keeps the layers on the
dGPU. Placement then works exactly as intended — dGPU held only 2505 MiB (non-expert + KV)
with ~19.6 GB of experts on the Arc.

**The measurement (UD-Q4_K_M, 8665-token prefill, warm):**

| config | prefill | decode |
|---|---|---|
| CUDA dGPU + CPU experts (incumbent) | **425 t/s** | **29.3 t/s** |
| Vulkan dGPU + CPU experts *(diagnostic)* | 224.8 t/s | 9.67 t/s |
| Vulkan dGPU + **Arc** experts *(the idea)* | 135.5 t/s | 12.00 t/s |

Decomposed, which is the whole point of running the middle row:

```
CUDA->Vulkan   (expert device held at CPU)   prefill -47%   decode -67%
CPU->Arc       (backend held at Vulkan)      prefill -40%   decode +24%
```

**The Arc really is faster than the CPU at expert gather — +24% decode.** That part of the
intuition is correct. But the Vulkan backend costs 67% of decode first, and recovering 24%
of what remains nets out to **12.0 t/s vs 29.3 — 2.4x slower than doing nothing.** The Arc
also *hurts* prefill (224.8 -> 135.5), consistent with the tiny-tier finding below that its
expert gathers are inefficient; prefill activates many experts per batch, so it is hit hardest.

Two structural reasons this was never going to pay, worth remembering before re-proposing it:

- **The Arc is not a second memory pool.** Its "47779 MiB" is system RAM on the same LPDDR5x
  bus the CPU uses. Moving expert work there adds a second *compute unit*, not bandwidth.
- **CUDA is worth more than the iGPU.** Any dual-GPU scheme on this laptop must go through
  Vulkan, because CUDA cannot see the Intel device — so it pays the -67% before it starts.

**Practical trap while testing:** the Arc allocates against `MemFree`, not `MemAvailable`.
Holding ~19.6 GB of experts there drove the host to **529 MiB free with zram swap already
full**, and the whole llama-swap stack was killed off. Tear down the test container
(`podman rm -f ...`) before drawing conclusions about a "hang", and expect to
`podman-compose --profile laptop up -d` afterwards.

### The vision floor moves with the quant, and text tests will not find it

`qwen3.6-35b` crashes on image requests at `--n-cpu-moe 32` — `upstream process exited
unexpectedly`, HTTP 502, process gone. The old IQ4_XS build crashed at N=30 for the same reason.
~600 MiB of headroom cannot supply the vision encoder's compute buffer.

**Every crashing configuration passes a full 6524-token text prefill.** Text-only benchmarking will
not reveal this. Always send an image after re-tuning `--n-cpu-moe` on a model with `--mmproj`.

### The alias contract

Semantic aliases are the interface agents use — **never hardcode a checkpoint name**, it will
break on the other machine. The alias NAMES are identical across machines; only the right-hand
side differs. This is what lets one shared `~/.hermes/config.yaml` drive either box.

| alias | laptop | desktop | use |
|---|---|---|---|
| `local-main` | `qwen3.6-35b` (RTX 5070) | `qwen3.6-27b` (7900 XTX) | main agent, delegation, anything user-facing |
| `local-vision` | `qwen3.6-35b` (RTX 5070) | `qwen3.6-27b` | images/PDFs — same model as `local-main`, so no swap |
| `local-tiny` | `qwen3.5-2b` (Arc iGPU) | `gemma-4-12b` | background/fire-and-forget; **no vision, no reasoning** |
| `local-embed` | `embed` (Arc iGPU) | **MISSING** | RAG embeddings, 1024-dim |

Models with **no alias** are still reachable by name: `gemma-4-26b` and `qwen3.5-9b` on the laptop.
Requesting one evicts the loaded model (~15-30s swap) — only one fits in 8GB.

> **Known asymmetry:** `local-embed` exists only on the laptop — the desktop has no embedding
> GGUF, so the alias is absent from `litellm-config.desktop.yaml`. Anything routed to
> `local-embed` will fail there. Either download an embedding model on the desktop and add the
> alias, or keep embedding consumers laptop-only. Do not "fix" this by pointing `local-embed` at
> a chat model — a chat deployment cannot serve `/v1/embeddings`.

There is deliberately **no `local-support`**. It existed briefly, resolved to the same iGPU model
as `local-tiny`, and never had a consumer — two names for one thing is just a way to drift out of
sync. If background delegation ever needs its own tier, add the alias back to both litellm configs.

**`local-vision` now has a fallback, which it could not before.** Both `qwen3.6-35b` and
`gemma-4-26b` carry projectors, so vision degrades from one to the other instead of failing. It
must never fall back to `qwen3.5-9b` or `qwen3.5-2b` — neither has a projector, and a blind model
confidently describing an image it cannot see is worse than a clean error.

**Delegation runs on `local-main`, not the secondary GPU — this is measured, not assumed.**

| delegate_task, identical prompt | wall time |
|---|---|
| `local-main` (RTX 5070) | **33.6s** |
| the Arc iGPU (`gemma-4-e2b`, since replaced) | 2m05.8s |

Three reasons the "parallel lane" does not pay off: during synchronous delegation the parent is
idle so the primary GPU is free anyway (and the child reuses the already-loaded model, no
eviction); each llama-swap instance is `--parallel 1`, so concurrent children serialize on the iGPU
exactly as they would on the dGPU; and subagent cost is **prefill-dominated** (large system
prompt), where the iGPU is weakest. The iGPU wins only for `background=true` delegation, where the
parent really is generating at the same time.

## Hermes wiring (`~/.hermes/config.yaml`)

That file is **shared between both machines** and names only aliases. Relevant keys:

- `model.default: local-main` — the main agent.
- `delegation.model: local-main` — subagents (see measurement above). `provider`/`base_url`/
  `api_key` left empty so children inherit the parent's LiteLLM endpoint.
- `custom_providers[0].models.*.context_length` — pinned to **65536** for every alias. Without
  these, Hermes reads `*.context_length` from GGUF metadata and advertises the model's native
  window (256K for both large models), overrunning the actual `--ctx-size` KV allocation. Values
  are the **minimum across both machines**, so the shared file is safe either way.
- `auxiliary.<task>.{provider,model,base_url,api_key,timeout}` — 15 side tasks, each pinned.
  `base_url` is set explicitly on every one so they can never silently fall back to openrouter
  (no key is configured here).

Auxiliary tasks split on **critical path vs background**, not on prompt size:

| tier | tasks |
|---|---|
| `local-main` (dGPU) | `compression`, `mcp`, `skills_hub`, `triage_specifier`, `kanban_decomposer`, `goal_judge` |
| `local-vision` (dGPU) | `vision` |
| `local-tiny` (iGPU) | `title_generation`, `curator`, `profile_describer`, `monitor`, `tts_audio_tags`, `web_extract`, `approval`, `memory_query_rewrite` |

Anything the user waits on goes to `local-main` — it is faster *and* reuses the already-loaded
model. Fire-and-forget work goes to `local-tiny` on the iGPU specifically so it does **not** evict
the large model from the 8GB card. Timeouts are raised well above Hermes' defaults (120s
compression / 360s web_extract) because local models are slow and a timeout mid-compression drops
context rather than degrading gracefully.

**`approval` MUST stay on a non-thinking model — this is a correctness constraint, not a
preference.** `tools/approval.py::_smart_approve` sends `max_tokens=16, temperature=0` and expects
exactly one word (`APPROVE`/`DENY`/`ESCALATE`). On a thinking model the entire budget goes to
reasoning. Measured on the identical prompt:

| tier | model | result |
|---|---|---|
| `local-main` | qwen3.6-35b (thinking on) | `finish=length`, 64 chars reasoning, **content `''`** |
| `local-tiny` | qwen3.5-2b (`--reasoning off`) | `finish=stop`, 0 reasoning, **`APPROVE`** |

So smart approval was silently broken while it pointed at `local-main`. It now points at
`local-tiny`. Do not move it back without also raising `max_tokens` in `tools/approval.py` —
which is upstream code, so prefer leaving it here. `approvals.mode` resolves to `smart` by default
even though the user config has no `approvals:` block.

**Caveat on verifying it:** I could not get `_smart_approve` to fire from a `hermes -z` one-shot
run even with a command the scanner flags (`chmod -R 777 ...`, confirmed flagged via
`detect_dangerous_command`). Non-interactive runs appear to bypass the approval path. Verify in an
interactive session, watching `podman logs llama_swap_intel | grep -c "POST /v1/chat/completions"`.

**`memory_query_rewrite` almost certainly never fires here.** It is referenced only by
`plugins/memory/query_rewrite.py` and the Honcho plugin — i.e. **external** memory providers.
`memory.provider` is empty (built-in, non-vector memory), so nothing invokes it. It was pointed at
`local-tiny` for consistency, not effect.

**`auxiliary.web_extract` is misleadingly named, and fires rarely.** It does *not* control the
`web_extract` tool — `tools/web_tools.py` makes **no LLM call at all**, it truncates page text at
`DEFAULT_EXTRACT_CHAR_LIMIT` (15000 chars) and stores the full copy on disk for `read_file` paging.
The setting is consumed by `tools/browser_tool.py`, which summarises **browser page snapshots**
with it (`task="web_extract"`, `max_tokens=4000`, `temperature=0.1`). Its gate is narrow:

```python
if len(snapshot_text) > SNAPSHOT_SUMMARIZE_THRESHOLD and user_task:   # 15000 chars
    snapshot_text = _extract_relevant_content(snapshot_text, user_task)
elif len(snapshot_text) > SNAPSHOT_SUMMARIZE_THRESHOLD:
    snapshot_text = _truncate_snapshot(snapshot_text)                  # no LLM
```

It was routed to `local-tiny` as a trial (2026-08-03). **In three realistic attempts — a plain
page fetch, a browser navigation, and a deliberately link-heavy page — it never fired once**; the
main agent read the content directly each time. Verify with request counts before concluding a
change to it did anything:

```bash
podman logs llama_swap_intel | grep -c "POST /v1/chat/completions"   # before and after
```

`AUXILIARY_WEB_EXTRACT_MODEL` (env) overrides the config value; it is unset here.

**Hermes cannot consume `local-embed`.** There is no embedding config key anywhere in
`hermes_cli/config_defaults.py` and nothing in the agent calls `/embeddings`; its built-in memory
is not vector-based, and the external providers that do use embeddings (Hindsight) run
`sentence-transformers` locally rather than hitting an OpenAI-compatible endpoint. `local-embed`
is for the qdrant/n8n stack (`ai/n8n.yml`), `ai/research.yml`, or direct API use.

## The tiny tier: model choice, and why dense beats sparse here

`qwen3.5-2b` replaced `gemma-4-e2b` after benchmarking. Same iGPU, 64K ctx, 6524-token prefill,
two interleaved rounds:

| model | file | prefill | decode |
|---|---|---|---|
| `gemma-4-e2b` (was) | 3.00 GiB | 176.1 t/s | 16.3 t/s |
| **`qwen3.5-2b` (now)** | **1.28 GiB** | **557.7 t/s** | **23.1 t/s** |
| `Qwen3.5-4B` (rejected) | 2.71 GiB | 221.0 t/s | 11.9 t/s |
| `gemma-4-e4b` (rejected) | 4.80 GiB | 141.2 t/s | 10.4 t/s |
| `qwen3.5-9b` (rejected) | 5.60 GiB | 190.9 t/s | 7.4 t/s |

**Dense beats sparse on this iGPU.** `gemma-4-e2b` and `-e4b` are MoE, and their expert gathers
are inefficient here; a plain dense 2B saturates the device far better. The pattern is consistent:
even dense `qwen3.5-9b` out-prefilled the 2B-active MoE. Prefill is compute-bound matrix-matrix
work; decode is bandwidth-bound and scales with active parameters, which is why the 9B collapses
to 7.4 t/s. **At the small end on this hardware, prefer dense.**

Capability was verified equal, not assumed: single tool call, tool *selection* among four schemas
with three required args, tool-result round-trip, and correctly declining to call a tool — all
three candidates passed. Accuracy at temp 0 was identical. `qwen3.5-2b` additionally returns clean
JSON where `gemma-4-e2b` wrapped it in ` ```json ` fences a consumer had to strip. It retrieved a
needle at 60% depth in a 49,970-token context.

**Two traps found while evaluating it:**

1. **Unsloth's docs are wrong about default thinking.** They state the Qwen3.5 Small series
   (0.8B/2B/4B/9B) has reasoning disabled by default. With this llama.cpp build it does not —
   tested without the flag, the 2B emitted ~1388 chars of reasoning and hit the token cap with
   **empty content**. The 4B *model card* (which says thinking is on) is the accurate source.
   `--reasoning off` is still required.
2. **Unsloth's recommended `presence_penalty` 1.5-2.0 destabilises short factual output.** At
   temp 0.7 + presence_penalty 1.5 the 2B answered "17 times 4" as **56**; at temp 0 it answers 68.
   The config uses 0.5. This nearly got recorded as a capability gap — it was sampling noise.

**Context scaling is the reason this tier is not for big prompts.** Prefill collapses as context
grows (attention is quadratic and the device is bandwidth-bound):

| context | `qwen3.5-2b` prefill | time to ingest |
|---|---|---|
| 6.5K | 558 tok/s | 12s |
| 19K | 252 tok/s | 75s |
| 50K | 103 tok/s | **485s** |

The dGPU holds ~396 tok/s at 19K. So **small prompts → iGPU wins; large prompts → dGPU wins**,
and the crossover is around 10-15K tokens.

## The tiny tier: no vision, no reasoning

Every model here is a thinking model, which is pure waste for `local-tiny` work. Measured on a
realistic title-generation prompt (identical three-word answer in every case):

| configuration | completion tokens | reasoning leaked into `content`? |
|---|---|---|
| default (thinking on) | 302 (~40s) | no — but ~290 tokens wasted |
| `--reasoning-budget 0` | 358 | **YES** |
| `--reasoning off` | **101-111 (~17s)** | no |

Three traps, all of which fail silently:

1. **`--reasoning-budget 0` is not an off switch.** It suppresses thought-tag *parsing* only — the
   model still reasons, and the trace lands in `message.content`. Session titles come back reading
   `"Thinking Process:\n\n1. **Analyze the conversation**..."`. It measured *worse* than leaving
   thinking on. Use `--reasoning off`.
2. **Per-request `reasoning_effort` does not work through LiteLLM.** Sent straight to llama-server
   it works perfectly (108 tokens, zero reasoning). Sent through the gateway with the identical
   body it is **silently dropped** — 310 tokens with full reasoning, no warning. `drop_params: true`
   strips it for `openai/`-prefixed custom endpoints. Thinking must be off at the *server*.
3. Reasoning is a **server-level** flag, so it is set on the process, not the request.

**Vision is also absent from this tier**, deliberately: `local-vision` resolves to the dGPU, which
has a far better vision model. The tier model correctly rejects images with `image input is not
supported - hint: if this is unexpected, you may need to provide the mmproj`.

Caveat: `--reasoning off` removes the reasoning waste, not verbosity. Given a vague prompt a small
model still rambles to the `max_tokens` cap; given a well-specified one ("Reply with ONLY the
title") it answers in ~5-8 tokens. The chattiness once blamed on `gemma-4-e2b` was a **prompt**
problem, not a model problem — worth fixing the prompt before swapping a model.

## Embeddings

`embed` = `Qwen3-Embedding-0.6B-Q8_0.gguf`, 1024-dim, 28 layers, native ctx 32768, on the iGPU.
Two non-obvious constraints:

- **`--pooling last`, NOT `mean`.** The GGUF declares `pooling_type: 3` (LAST) — Qwen3-Embedding
  derives the sentence vector from the final token rather than averaging. Passing `mean` produces
  degraded embeddings that still look plausible: unit-norm vectors, no error, just worse retrieval.
  llama.cpp uses the model default when `--pooling` is omitted; it is stated explicitly so nobody
  "corrects" it later. Sanity check after any change — related pairs must separate from unrelated
  ones (measured: `cat~kitten` 0.673, `db~sql` 0.809, `cat~db` 0.308, `kitten~sql` 0.204).
- **`--ubatch-size` must be >= the longest input.** With pooling enabled the whole sequence must fit
  in a single ubatch, so ubatch is pinned to `--ctx-size` (8192). That covers any realistic RAG
  chunk (typically 512-1024) without sizing the compute buffer for the full 32768 window.

This server is **embeddings only** — it cannot serve `/v1/chat/completions`.

## Per-device notes

- **Intel iGPU (Arc)** — SYCL, via upstream-tracking `llama-swap:intel` image (`intel_llama_swap`
  profile). Runs two `llama-server` processes, **both resident simultaneously** via a `groups:`
  block with `swap: false`: `qwen3.5-2b` (`local-tiny`) and `embed` (`local-embed`). RAG and
  background calls interleave constantly, so letting them evict each other would add a reload to
  every switch. Measured resident total **2.14 GB** against 62GB of system RAM.
  **Cold-start gotcha:** the `intel_sycl_cache` named volume (mounted at `/root/.cache`) persists
  the SYCL/Level-Zero JIT kernel cache across container restarts. Without it, every recreate
  recompiles all GPU kernels from scratch — measured 4m32s for the first request after a fresh
  volume vs. 18s once warm. If iGPU requests look "stuck"/timed-out right after `up`, that's this,
  not a broken deployment — wait it out once, or warm it manually before sending real traffic.
  Client-side timeouts are often shorter than the cold-compile time, so the first real request can
  look like total failure (200 response, 0-byte body) even though the backend is fine.
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

Request flow: agents -> LiteLLM (`:4000`) -> the appropriate llama-swap instance (`:8081` primary
GPU / `:8082` iGPU on the host) -> spawned `llama-server` subprocess per model. LiteLLM also routes
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

| model | n_embd | native ctx | projector file | in use |
|---|---|---|---|---|
| qwen3.6-35b | 2048 | 256K | `qwen3.6-35b-mmproj-F16.gguf` | **laptop `local-vision`** + desktop |
| gemma-4-26b | 2816 | 256K | `gemma-4-26b-mmproj-F16.gguf` | laptop vision fallback + desktop |
| gemma-4-12b | 3840 | 256K | `gemma-4-12b-mmproj-F16.gguf` | desktop |
| gemma-4-e4b | 2560 | 128K | `gemma-4-e4b-mmproj-F16.gguf` | no longer used |
| gemma-4-e2b | 1536 | 128K | `gemma-4-e2b-mmproj-F16.gguf` | **not loaded** — removed from the tiny tier |

Qwen 3.6 27b also uses its own per-model projector.

**Adding a vision model:** read the GGUF `*.embedding_length` metadata, then fetch the projector
from *that exact model's* Unsloth `*-GGUF` repo (file is `mmproj-F16.gguf`), saved as
`<model>-mmproj-F16.gguf`. Never reuse another size's projector.

## Build-specific facts

The three images (`llama-swap:rocm` desktop, `:cuda` and `:intel` laptop) track upstream llama.cpp
and behave the same on these points:

- `--jinja` is **enabled by default** — do not add it; chat templates + reasoning extraction work.
- `--flash-attn` needs an explicit value: `--flash-attn on`.
- Qwen 3.6 is supported out of the box — the "must build from source for Qwen3.6 rope" advice from
  older guides does **not** apply.
- Available and used: `--cache-reuse`, `--batch-size`/`--ubatch-size`, `--cache-type-k/v`,
  `--n-cpu-moe`, `--reasoning`, `--pooling`, `--embedding`, per-model sampling flags.
- **No MTP (multi-token prediction) support.** There is no `--mtp` flag; every speculative-decoding
  option (`--spec-draft-model`, `--spec-draft-hf`, `--spec-draft-ngl`, ...) requires a *separate
  draft model file*. Unsloth's `MTP-GGUF` variants carry weights this build cannot activate, so
  they are a larger download for identical speed. Re-check after a llama.cpp upgrade — decode here
  is memory-bound, exactly the regime where speculative decoding pays off most.

## Context: metadata vs runtime

Clients read `*.context_length` from GGUF metadata and advertise the model's **native training
context** (256K for both large models), regardless of the runtime `--ctx-size` cap. The actual KV
allocation is whatever `--ctx-size` sets. For Hermes this is not cosmetic — it is pinned explicitly
per alias in `custom_providers[0].models`. When changing a model's `--ctx-size`, update that map
too, and remember the runtime window must cover the **largest** alias pointing at that model.

## Tuning conventions in this config

- All models `--parallel 1` so `--ctx-size` is the full per-request window.
- 24GB tier: `q8_0` KV cache, `--ubatch-size` raised (2048 for the small-weight 12b, 1024 for the
  ~17GB models). Verify VRAM with `rocm-smi` after changing batch sizes; if a 17GB model OOMs,
  drop its `--ubatch-size` back to 512.
- 8GB dGPU tier (`llama-swap-nvidia.yaml`): `q4_0` KV cache — 8GB is a hard wall. At 64K ctx:
  `qwen3.6-35b` (UD-Q4_K_M) + `--n-cpu-moe 34` + mmproj = 6947 MiB (~1.2GB headroom) and
  `--threads 6 --cpu-range 0-5 --cpu-strict 1`; `gemma-4-26b` +
  `--n-cpu-moe 26` + mmproj = 6903 MiB (~1.2GB); `qwen3.5-9b` + `--ubatch-size 512` = 6303 MiB
  (~1.8GB). If a MoE model OOMs, raise `--n-cpu-moe` (trades decode for VRAM without touching
  context); for the dense `qwen3.5-9b`, step `--ubatch-size` 512 -> 384 -> 256, then ctx 64K -> 32K.
- iGPU tier (`llama-swap-intel.yaml`): `q8_0` KV and much larger batches than the dGPU tier,
  because the Arc iGPU has **no dedicated VRAM** — it allocates from 62GB of system RAM, so the
  8GB-tier concessions buy nothing there. Measured ubatch sweep on a 6524-token prefill:
  128 -> 104 tok/s, 512 -> 126, **1024 -> 146 (best)**, 2048 -> 136 (overshoots, regresses).
  The ceiling is memory bandwidth, not batch size: an 8x ubatch increase bought only ~40%.
  **Memory caveat:** the Arc iGPU reports free memory tracking host `MemFree`, not reclaimable
  `MemAvailable`. If a model fails to allocate, check `free -h` before lowering ubatch.
- Per-model sampling baked in as defaults (Qwen: temp 0.7/top-k 20/top-p 0.95/min-p 0;
  Gemma: temp 1.0/top-k 64/top-p 0.95). Clients can override per request.
- `groups:` with `swap: false` keeps multiple models resident in one instance. Used on the iGPU.
  **Not** usable on the 8GB dGPU — the large models cannot co-reside, so switching between them is
  an inherent ~15-30s swap.
- Deliberately not used: `--mlock` (fights llama-swap's TTL load/unload).

## Testing / verification

Two stdlib-only scripts live in `ai/bench/` — see `ai/bench/README.md`:

```bash
ai/bench/smoke.py                                  # health-check every tier + alias
ai/bench/llmbench.py --models a b --tests all      # compare models
ai/bench/llmbench.py --models local-main --fail-on-regression   # CI gate
```

`smoke.py` replays the exact `max_tokens=16` approval shape and flags empty-content
responses, which is how the smart-approval breakage was found. `llmbench.py` interleaves
models across rounds so thermal drift is shared rather than stacked. Raw curl equivalents:

```bash
# direct to a llama-swap instance (bypasses LiteLLM) — fastest way to smoke-test a model loads
curl -s localhost:8081/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.6-35b","messages":[{"role":"user","content":"hi"}],"max_tokens":400}'  # dGPU
curl -s localhost:8082/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.5-2b","messages":[{"role":"user","content":"hi"}],"max_tokens":400}'   # iGPU
curl -s localhost:8082/v1/embeddings -H 'Content-Type: application/json' \
  -d '{"model":"embed","input":"test"}'                                                      # iGPU

# confirm thinking is really off on the tiny tier — `reasoning` must be 0.
# Use a WELL-SPECIFIED prompt: given a vague one e2b rambles to the cap either way.
P='Generate a short title (max 6 words) for this conversation:\nUser: my postgres container keeps OOMing after about an hour\nAssistant: Lets check shared_buffers and work_mem first.'
curl -s localhost:8082/v1/chat/completions -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg p "$P" '{model:"qwen3.5-2b",messages:[{role:"user",content:$p}],max_tokens:400}')" \
  | jq '{tokens:.usage.completion_tokens, reasoning:(.choices[0].message.reasoning_content // "" | length)}'

# confirm vision is really gone from the tiny tier — must error, not answer
curl -s localhost:8082/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.5-2b","messages":[{"role":"user","content":[{"type":"text","text":"what is this?"},{"type":"image_url","image_url":{"url":"data:image/png;base64,iVBORw0KGgo="}}]}],"max_tokens":50}' \
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

**LiteLLM takes ~30-60s to become ready** after `up` or `restart`. Requests sent before then return
an empty body, which looks like a model failure but is not. Poll
`curl -s localhost:4000/health/liveliness` before benchmarking.

Gemma/Qwen are **thinking models**: with a small `max_tokens` the answer can land entirely in
`reasoning_content` with empty `content` and `finish_reason: length`. That's not a failure — raise
`max_tokens`. This bites harder than it sounds: `qwen3.5-9b` asked to "reply with just OK" spent
176 completion tokens reasoning before emitting `OK`, and returned **empty content** at
`max_tokens: 16`. Give local models generous budgets (400+) or agents will see blank replies.

**LiteLLM timeouts:** local inference is slow enough to trip LiteLLM's default request timeout —
a cold load plus a vision prefill measured 19.4s and surfaced as a useless
`InternalServerError - Connection error`. `request_timeout: 600` is set in both litellm configs;
don't lower it.

**LiteLLM fallbacks are matched on the requested name, not the resolved one.** A request for the
alias `local-vision` does *not* inherit a fallback declared for `qwen3.6-35b` — it fails with
`No fallback model group found for original model_group=local-vision`. Every alias needs its own
entry in the `fallbacks` list; keep them in sync when adding aliases.

**Do not list one machine's models in the other's litellm config.** The laptop config previously
carried the desktop's entries pointing at `llama_swap_server` (unreachable from the laptop), and
once the laptop gained its own `gemma-4-26b` deployment that became a duplicate `model_name` —
LiteLLM would have load-balanced across a live and a dead endpoint. Each config lists only what its
own machine can serve.
