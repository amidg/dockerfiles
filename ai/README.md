# Local LLM stack — llama.cpp + llama-swap (laptop) / Strata (desktop) + LiteLLM

Self-hosted inference for the Hermes agent across two machines. One OpenAI-compatible
endpoint, stable model names, per-machine engine behind them.

This file is **how to run it**. For why anything is tuned the way it is — and the traps
that cost hours — read [`AGENTS.md`](AGENTS.md).

## Run it

```bash
export LLAMA_MODELS_DIR=/var/mnt/data/llama/models     # where the GGUFs live
export STRATA_DATA_DIR=/var/mnt/data/llama/strata      # desktop only: Strata's /data

# laptop: RTX 5070 + Arc iGPU, both at once
podman-compose -f ai/llama-cpp.yml --profile laptop up -d

# desktop: 5070 Ti 16GB — builds and runs Strata (Swift 1.5 IQ2_XS)
podman-compose -f ai/llama-cpp.yml --profile server up -d --build
```

The desktop's `--build` compiles the Strata engine from the `ai/Strata` submodule on
first use (and after any submodule bump). LiteLLM needs ~30-60s. Poll before sending
traffic:

```bash
curl -s localhost:4000/health/liveliness
```

| endpoint | what |
|---|---|
| `localhost:4000/v1` | LiteLLM gateway — **point agents here** |
| `localhost:4000/ui` | admin (log in with `LITELLM_MASTER_KEY`) |
| `localhost:8081` | laptop primary GPU (RTX 5070), direct to llama-swap |
| `localhost:8082` | laptop secondary GPU (Arc iGPU), direct |
| `localhost:8083` | whisper-pro ASR (Intel NPU) — STT |
| `localhost:8080` | desktop Strata (5070 Ti), direct — **no auth, LAN-reachable** |

Secrets in `ai/litellm.env`, models in `$LLAMA_MODELS_DIR`.

## Desktop: Strata + Swift 1.5 (Qwen3.8-Flash-Next)

The desktop runs **Strata** (`ai/Strata`, pinned to its release tag) instead of llama.cpp:
a 125B-A6B MoE that never fits in VRAM, run as a GPU expert cache (5070 Ti 16GB) +
page-locked expert arena in system RAM + the n-gram table on the SSD. The 7900 XTX is the
display card and is **not** used for inference — Strata cannot mix HIP and CUDA in one run,
and its container is CUDA-only.

The weights are **Swift 1.5** (`ukisai/Swift-1.5-Qwen3.8-Flash-Next-…`, Strata family
`swift`) — UkisAI's post-train of the same model, tuned for ~63% fewer thinking tokens and
1.8× sooner answers at stated <1% quality loss. Its IQ2_XS measures better than the base
model's IQ2_XS on 7/8 eval sets at the same arena size. License: Swift Open License 1.0
(not Apache-2.0).

| | |
|---|---|
| GPU | 5070 Ti 16GB (`--vram-reserve` default) |
| RAM | expert arena capped at `STRATA_ARENA_PIN_GIB=40` of 96GB — **40GB is the maximum**, 48GB only for the documented worst case below |
| SSD | `${STRATA_DATA_DIR:-/var/mnt/data/llama/strata}` → `/data:z` (n-gram table, MTP draft, pack, caches) — the mount carries the SELinux `:z` label or the container cannot write it |
| context | 131072 |
| KV | `k8v4` |
| vision | **cpu** — the engine only recommends the GPU encoder at ≥23.5GB VRAM (upstream #2406); on 16GB the CPU encoder frees ~1.1-1.4GB for the expert cache at a 3-5% decode cost |
| model name | `qwen3.8-flash-next` (LiteLLM → `http://strata:8080/v1`) — deliberately names the Swift weights |

**Measured 2026-10-18** (first real run; full write-up in
[`reports/strata-report-2026-10-18.md`](reports/strata-report-2026-10-18.md)):
**2036 t/s prefill, 113.5 t/s deep decode**, tools 4/4, quality 4/4, a 50K-token needle in
20.9 s, vision correct on real 1280px images (~3 s each) — roughly **3× the laptop's main
model on deep decode**, with LiteLLM adding no measurable cost. Arena 33.0 GiB of the
40 GiB pin; warm restart 20 s.

### Weights to download (manual, into `$LLAMA_MODELS_DIR`)

```bash
export LLAMA_MODELS_DIR=/var/mnt/data/llama/models
cd $LLAMA_MODELS_DIR
hf download ukisai/Swift-1.5-Qwen3.8-Flash-Next-GSQ-RCO-GGUF \
  --include "Swift-Qwen3.8-Flash-Next-GSQ-RCO-IQ2_XS-*.gguf" \
  --include "mmproj-Swift-Qwen3.8-Flash-Next-BF16.gguf" \
  --local-dir .
```

- Swift **IQ2_XS** GGUF shards, **original filenames** — Strata matches the first shard by
  the canonical `*-00001-of-*.gguf` name containing the model name; roughly 68GB
- `mmproj-Swift-Qwen3.8-Flash-Next-BF16.gguf` (~0.91GB) — **Swift ships its own projector**;
  the base model's `mmproj-Qwen3.8-Flash-Next-BF16.gguf` is not reused
- **Do not download**: the base ISTA shards (not needed, ~28GB wasted), Swift `Q2_0`
  (Strata's packer cannot handle its shard split — upstream #171), or any MTP file
  (Strata fetches the draft, ~6GB, into `/data` on first start)

Strata writes `<shard>.done` checksum markers next to the GGUFs, which is why the models
dir is mounted writable.

### Roll out on the desktop (manual)

```bash
cd ~/Projects/dockerfiles
git pull --ff-only
git submodule update --init --checkout ai/Strata

export LLAMA_MODELS_DIR=/var/mnt/data/llama/models
export STRATA_DATA_DIR=/var/mnt/data/llama/strata   # override the compose default
hf download ukisai/... # the two lines above
mkdir -p "$STRATA_DATA_DIR"

podman-compose -f ai/llama-cpp.yml --profile server build strata
podman-compose -f ai/llama-cpp.yml --profile server up -d
podman logs -f strata        # minutes of expected silence: pack unpack, draft fetch, arena load
```

### First-boot checklist

1. **Health** — `curl -s 127.0.0.1:8080/health`.
2. **GPU wiring** — the engine must report the 5070 Ti (`podman logs strata | head -50`,
   Strata's `/v1/status`). `base_nvidia` works under podman: podman-compose turns the
   reservation into explicit device mounts *and* adds `security-opt label=disable` itself.
   Only if the log shows no GPU: `sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml`
   and swap the `extends: base_nvidia` block for `devices: ["nvidia.com/gpu=all"]`.
3. **Arena** — `curl -s 127.0.0.1:8080/metrics | jq '.engine.arena_mib'` (IQ2_XS ≈ 33 GiB,
   under the 40 GiB `STRATA_ARENA_PIN_GIB` cap). **Not `VmLck`** — this build pins with
   `cudaHostRegister`, which leaves `/proc/<pid>/status` at `VmLck: 0`. Confirm the desktop
   stays responsive.
4. **Model id** — `curl -s 127.0.0.1:8080/v1/models` advertises Strata's own id
   (`swift-1.5-iq2_xs`), which is **not** the gateway name. Leave the LiteLLM `model_name`
   as `qwen3.8-flash-next`; Strata accepts the forwarded name. The gateway would only need
   a change if Strata rejected it (it would 404/400, not silently misroute).
5. **Gateway** — after ~30-60s, `curl -s localhost:4000/health/liveliness`, then a real
   completion with `model: qwen3.8-flash-next` through `:4000/v1`. A `403 Host 'strata:8080'
   is not allowed` here means `STRATA_ALLOWED_HOSTS` lost its `strata` entry.

### Quant ladder (only step down this path if IQ2_XS disappoints)

| step | env | arena | cost |
|---|---|---|---|
| **default** | `MODEL=IQ2_XS FAMILY=swift STRATA_ARENA_PIN_GIB=40` | ~35.5 GiB | — |
| worst case | `MODEL=IQ3_XXS FAMILY=swift STRATA_ARENA_PIN_GIB=44` | ~42.9 GiB | ~15% slower decode, KLD 0.341 → 0.240 |
| out of scope | `IQ3_S` (50.3), Unsloth `UD-Q4_K_XL` (77), `NVFP4` (68) | — | exceeds the 48GB worst case |

**Never raise the pin past 48GB**, and the base-model rollback is `FAMILY=qwen` plus the
base mmproj (same `MODEL=IQ2_XS`).

## Whisper ASR (Intel NPU)

Local speech-to-text on `ventura8/whisper-pro-asr:intel`, running **whisper-small-int4** on
the **Intel NPU**. Runs **inside** `llama-cpp.yml` as the `intel_npu_whisper` service
(profiles `laptop` + `whisper`) — not a separate stack. Host `:8083` → container `:9000`.

```bash
# already up under the laptop profile:
podman-compose -f ai/llama-cpp.yml --profile laptop up -d

# whisper only:
podman-compose -f ai/llama-cpp.yml --profile laptop --profile whisper up -d intel_npu_whisper
```

Weights are not downloaded by the container — they are bind-mounted read-only from
`$LLAMA_MODELS_DIR/whisper-small-int4-ov` to `/models/whisper-openvino`, which whisper-pro
loads when present (otherwise it fetches its own default, large-v3). Fetch them with:

```bash
hf download anubhav200/openai-whisper-small-openvino-int4 \
  --local-dir /mnt/data/llama/models/whisper-small-int4-ov
```

| endpoint | what |
|---|---|
| `localhost:8083` | whisper-pro ASR server (direct, no auth) |
| `localhost:4000/v1`, model `whisper` | via LiteLLM — **what Hermes STT uses** |

Direct (no auth, `response_format` = `json` / `srt` / `segments`):

```bash
curl -s http://localhost:8083/v1/audio/transcriptions \
  -F "file=@/path/to/audio.mp3" -F "model=whisper-large-v3" -F "response_format=json"
```

LiteLLM maps alias `whisper` → `http://whisper_server:9000/v1`
(`model_info: mode: audio_transcription`, container-internal port — **not** the host
`:8083`). Hermes is wired to it via `stt.provider: openai`,
`stt.openai.base_url: http://localhost:4000/v1`, `stt.openai.model: whisper`.

**UVR is the trap.** UVR = **Ultimate Vocal Remover** — a source-separation model
(MDX-NET) that strips background music/noise and keeps only the vocals *before*
transcription. whisper-pro runs it on the iGPU, and by default it ran **twice** per
request (once in the main pipeline, once inside language-detection preprocessing),
adding ~25 s each. That, not the NPU, was the slowness — the whisper inference itself
is ~1 s. For clean voice input UVR buys nothing, so both passes are off:

| env | default | here | controls |
|---|---|---|---|
| `ENABLE_VOCAL_SEPARATION` | `true` | `false` | the main UVR pass |
| `ENABLE_LD_PREPROCESSING` | `true` | `false` | the LD UVR pass (the sneaky second one) |

Re-enable both only for music-heavy source material.

### Model, and why the NPU (research)

**whisper-small-int4 on the Intel NPU.** whisper-pro-asr ships a conservative gate: before
using the NPU it reads the OpenVINO IR and refuses it if any input is dynamically shaped.
Every optimum-produced Whisper export is dynamic, so the gate forces ASR onto the CPU — but
**OpenVINO 2026.3.1 executes those IRs on the NPU fine**, so the gate is set aside with
`VERIFY_RUNTIME=false` (which only skips that probe, the engine's NPU warm-up, and a startup
ONNX-diagnostics log). `ASR_DEVICE=NPU` then pins the device.

Measured on a 60 s clip (laptop; the iGPU now runs embeddings only):

| model | device | build | inference (60 s) |
|---|---|---|---|
| **small-int4** | **NPU** | 21.5 s | **4.8 s** |
| small-int4 | iGPU | 6.5 s | 7.0 s |
| small-int4 | CPU | 0.7 s | 6.7 s |
| large-v3-turbo-fp16 | NPU | 179 s | 8.2 s |
| large-v3-turbo-fp16 | iGPU | 6.2 s | 4.4 s |
| large-v3-turbo-fp16 | CPU | 0.6 s | 26.8 s |

End-to-end through the service (warm): **~5.1 s per 60 s clip** on the NPU (inference
~4.2 s) and **54 s for the full 10-minute video**; the first request after a container
recreate adds the ~21 s NPU compile. small-int4 is the faster of the two on the NPU (turbo
pays a ~179 s compile and is still slower per clip). It is a **small int4** model, so it is
less accurate than large-v3-turbo — put turbo back on the iGPU if accuracy matters more
than the NPU.

### Residency and cold starts

By default the model is unloaded **300 s after the last request** (`MODEL_IDLE_TIMEOUT=300`),
and the NPU **recompiles on every (re)load** — the compiled blob is never cached to disk
(the ASR pipeline is built with no `cache_dir`; the banner's "Binary Cache Status" is a
false positive that just sees the `temp/` subdir). So the service sets
**`MODEL_IDLE_TIMEOUT=0`**, which makes the model permanently resident in NPU memory for the
container's lifetime, plus **`restart: unless-stopped`** so a reboot/crash does not need a
manual `up`. Only an actual container recreate (config edit, image update) pays the compile
again: **~21 s for small-int4**, ~179 s for large-v3-turbo.

## Architecture

```
agents ──> LiteLLM :4000 ──┬──> llama-swap :8081 ──> llama-server (laptop primary GPU)
           (model names,    │
            routing)        └──> llama-swap :8082 ──> llama-server (laptop iGPU)

agents ──> LiteLLM :4000 ──────> Strata :8080        (desktop, 5070 Ti)
```

LiteLLM forwards a requested model name to whichever engine owns it. On the laptop,
llama-swap spawns and kills one `llama-server` per model on demand and unloads after an
idle TTL. On the desktop, Strata is a single long-resident process — there is nothing to
swap, and the desktop's gateway exposes exactly one local model.

## Use the model names

Direct names, no aliases. The laptop and the desktop serve different names — a shared
`~/.hermes/config.yaml` points at whichever box it is talking to.

| name | machine | engine | for |
|---|---|---|---|
| `qwen3.8-flash-next` | desktop | Strata, 5070 Ti, 131K, Swift 1.5 weights | main agent, delegation, vision (CPU encoder), anything user-facing |
| `tiel-coder-35b` | laptop | llama-swap, RTX 5070, MTP, 131K, Q3_K_XL, vision on CPU | **default agent, delegation, aux tasks, vision** (40.1 t/s deep, 1442 t/s prefill) |
| `gemma-4-26b-a4b` | laptop | llama-swap, RTX 5070, MTP, vision, 131K, N=27 | on-demand alternative (GPU vision, 35.0 t/s deep); nothing routes to it by default |
| `gemma-4-e4b` | laptop | llama-swap, RTX 5070, MTP, 128K | on-demand fallback (fast, vision, audio); nothing routes to it by default |
| `embeddinggemma-2` | laptop | llama-swap, Arc iGPU | embeddings |
| `whisper` | laptop | whisper-pro ASR, Intel NPU | STT |

The desktop's LiteLLM serves **only** `qwen3.8-flash-next` locally now — the cloud
Anthropic/Gemini entries were dropped with the llama.cpp migration.

```bash
curl -s localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.8-flash-next","messages":[{"role":"user","content":"hi"}],"max_tokens":400}'
```

## What runs where (laptop)

| device | port | models | role |
|---|---|---|---|
| RTX 5070 8GB | 8081 | `tiel-coder-35b` (default, MTP, vision on CPU, 131K, ttl 0), `gemma-4-26b-a4b` (MTP, vision, 131K, on-demand), `gemma-4-e4b` (MTP, vision, 128K, on-demand) | everything the user waits on |
| Arc Pro iGPU | 8082 | `embeddinggemma-2` (embeddings) | embeddings |
| Intel NPU | 8083 | `whisper-small-int4` (whisper-pro ASR) | STT — NPU inference, UVR off |

Only **one** dGPU model is resident at a time — requesting another costs a ~15-30s swap.

### Weights on the laptop (manual, into `$LLAMA_MODELS_DIR`)

- `gemma-4-26B-A4B-it-qat-UD-Q4_K_XL.gguf` (14.25GB), `mmproj-F16.gguf` (1.19GB — the
  projector, from the same `gemma-4-26B-A4B-it-qat-GGUF` repo) and
  `mtp-gemma-4-26B-A4B-it.gguf` (252MB) — the main dGPU model. Verify sha256 after
  downloading; a truncated GGUF fails at load, not at download.
- `gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf` + `gemma-4-e4b-qat-mmproj-F16.gguf` +
  `mtp-gemma-4-E4B-it.gguf` — the on-demand fallback.
- `Tiel-Coder-35B-A3B-MTP-UD-Q3_K_XL.gguf` (17.2GB) + `tiel-coder-35b-mmproj-BF16.gguf`
  (903MB, from the same `peculiar-ragdoll/Tiel-Coder-35B-A3B-GGUF-MTP` repo) — the on-demand
  coding model. Projector on the CPU (`--no-mmproj-offload`) like the Qwen below.
- `Qwen3.6-35B-A3B-UD-Q3_K_XL.gguf` (17.2GB) + `qwen3.6-35b-mmproj-F16.gguf` (899MB) —
  **kept on disk, unwired**: lost the 2026-10-18 A/B to tiel (agentic task time, image OCR).
  To re-test, add a llama-swap entry; nothing else needs to change.
- `embeddinggemma-2-Q8_0.gguf` — embeddings, the only iGPU model.
- Deleted 2026-10-18 (re-downloadable if ever wanted back): the Tiel-Coder-35B and both
  LFM2.5-24B GGUFs.

## What runs where (desktop)

| device | port | model | role |
|---|---|---|---|
| 5070 Ti 16GB | 8080 | `qwen3.8-flash-next` (Strata, Swift 1.5 IQ2_XS, 131K, vision on CPU, `k8v4` KV) | everything — the only inference engine on the box |
| 7900 XTX 24GB | — | — | display only; Strata's container is CUDA-only and cannot mix vendors |

Strata never swaps models: the expert arena is page-locked in RAM and stays there, which
is why the desktop has one model where the laptop has four.

## Key findings

The short version. Measurements and reasoning are in [`AGENTS.md`](AGENTS.md).

- **A 35B runs on an 8GB card** via `--n-cpu-moe`, which keeps Mixture-of-Experts weights
  (~90% of the file) in system RAM while attention and KV stay on the GPU.
  `qwen3.6-35b` → **991 t/s prefill, 46.3 t/s decode, 128K context, ~7275 MiB**.
- **A dense 9B runs MTP at 64K** — `qwen3.5-9b` → **1936 t/s prefill, 57.3 t/s decode,
  66.8 t/s deep, 7580 MiB**, 84% draft acceptance at depth. 64K context fits with MTP;
  128K does not (VRAM ceiling). 52% faster deep than qwen3.6-35b, 4/4 tools, 4/4 quality.
- **128K is the default**, validated on a real 118,018-token prompt. Buy context headroom by
  lowering `--ubatch-size`, never by raising `--n-cpu-moe`: at 96K the two routes were
  measured head to head and ubatch cost **zero** decode while N cost 2.3%.
- **Q4_K_M is the quant floor here.** Both a smaller K-quant (Q3_K_XL) and an i-quant
  (IQ4_XS) lose on decode despite reading fewer bytes: dequantisation cost on this
  AVX2-only CPU outweighs the saving.
- **MTP is the biggest single win on this box: 1.53x decode at 6.5K, 2.59x at 58K.**
  Published MoE figures (1.17-1.40x) badly understate it, because they were measured on
  fully-GPU-resident models that had no batching slack left. With experts on the CPU there
  is a 14x gap between prefill and batch-1 decode, and MTP collects it. Use
  `--spec-draft-n-max 2`; **3 is not lossless on this build**.
- **`--ubatch-size` is the dGPU's context lever.** 2048 gives peak prefill (1323 t/s) at 64K;
  1024 is what makes 128K fit, costing ~25% prefill and no decode.
- **`--load-mode none` beats mmap** when experts are CPU-resident — llama.cpp says so on
  every load, and it is right (+decode, +prefill, no cold-start penalty).
- **`gemma-4-26b` runs MTP too** (+9% decode), and there it *frees* VRAM rather than costing
  it: offloading the experts to make room releases more than the 462 MB draft head uses, so
  the MTP config is both faster and has 3x the vision headroom of the one it replaced.
  Gemma's MTP head is a **separate `--model-draft` file**; Qwen3.6's is bundled.
- **Decode is two different numbers.** Generation from a short prompt is much faster than
  generation continuing from a large one. Judge an agent tier on the latter — it is what a
  Hermes turn actually does.
- **Fewer, faster CPU threads win.** `--threads 6` pinned to the P-cores beats the default
  16 by ~5% and beats 12 or 14 threads by ~40%. Prefill is unaffected.
- **`--n-cpu-moe` is cheap without MTP and expensive with it** — and non-linear: N=36 costs
  3.3 t/s more than N=35. Buy VRAM headroom from `--ubatch-size` first.
- **Splitting the model across both GPUs with Vulkan was tested and rejected**: the iGPU
  does beat the CPU at expert work (+24%), but leaving CUDA for Vulkan costs 67% first.
- **Text tests will not catch a vision crash.** Always send a real image after retuning.
- **At the small end, prefer dense over MoE** — expert gathers are inefficient on the Arc.
- **MTP is a LOSS on the iGPU** (-25% deep on the retired `gemma-4-e2b`) even though it is the biggest
  win on the dGPU. The dGPU has CPU-offloaded experts with batching slack; the Arc is
  GPU-resident and bandwidth-bound, so speculative verification costs more than it saves.
  It also *improves* the shallow number, so judging on `decode` would ship a regression.
- **iGPU KV is `f16`, not `q8_0`** — taken for precision, not speed: the +4% was inside
  noise, but f16 is never worse and its 2x cost is system RAM, which is free on that tier.

## Check it works

The benchmark harness lives in a separate repo:
[amidg/llm-benchmarking](https://github.com/amidg/llm-benchmarking).

```bash
git clone git@github.com:amidg/llm-benchmarking.git
cd llm-benchmarking
export LITELLM_ENV=~/Projects/dockerfiles/ai/litellm.env

./smoke.py          # every tier, every model, vision, approval shape
./smoke.py --quick  # just show what is loaded where

./llmbench.py --models tiel-coder-35b gemma-4-26b-a4b --tests all
```

On the **desktop**, llama-swap is not on :8081 — the local model is Strata on :8080, so
either edit `TIERS` in `smoke.py` or drive it directly:
`llmbench.py --endpoint http://localhost:8080/v1`. Gateway checks are unaffected (LiteLLM
is :4000 on both machines).

## Files

| file | what |
|---|---|
| `llama-cpp.yml` | compose: laptop llama-swap instances, desktop Strata, LiteLLM, postgres |
| `llama-swap-nvidia.yaml` | laptop primary GPU |
| `llama-swap-intel.yaml` | laptop secondary GPU (iGPU) |
| `litellm-config.laptop.yaml` | laptop gateway: local + remote model names |
| `litellm-config.desktop.yaml` | desktop gateway: `qwen3.8-flash-next` → Strata only |
| `Strata/` | git submodule — the desktop inference engine (pinned release tag) |
| `litellm.env` | secrets (gitignored) |
| `AGENTS.md` | **rules, rationale, learnings — read before editing any config** |

Configs deliberately carry **no comments**; all rationale lives in `AGENTS.md`.

## Troubleshooting

**Config edit had no effect.** Editing a bind-mounted file replaces its inode, so the
container keeps the old one. `podman restart llama_swap_nvidia`.

**Connection reset / container shows `(unhealthy)`.** `localhost` resolves to `::1` but
llama-server binds IPv4. Use `127.0.0.1`.

**Empty response right after `up`.** LiteLLM still starting (~30-60s — poll
`/health/liveliness`), or the Arc is JIT-compiling SYCL kernels on a cold cache (one-time,
took 4m32s once; the `intel_sycl_cache` volume prevents a repeat).

**Blank `content` with filled `reasoning_content`.** Thinking model, budget ran out. Raise
`max_tokens` to 400+.

**Answers text fine but dies on images.** The laptop dGPU's `gemma-4-26b-a4b` carries a
projector (as does the desktop's `qwen3.8-flash-next`), so an image request is expected to
work there. The failure mode to know is the opposite one: a config that passes every text
test can still kill the server on a real image when VRAM headroom cannot fit the vision
encoder's buffer — test with a generated 1280px image, not a 1×1 PNG.

**A single-model `llmbench` run reports nonsense prefill on rounds 2+.** The prompt is
byte-identical every round, so it hits the server-side prompt cache, `prompt_n` collapses
to ~4 tokens and `prefill_tps` becomes noise (round 1 is the only valid one). Always pass
**two or more** `--models` — alternating flushes the cache. This has looked like a
performance regression twice.

**Never port llama.cpp tuning between the laptop and the desktop.** The desktop no longer
runs llama.cpp — there is no `--n-cpu-moe`, `--ubatch-size` or `--threads` to copy, and
Strata's memory model (VRAM expert cache + 40GiB pinned RAM arena + n-gram table on the
SSD) is not llama.cpp's. Laptop flags are laptop flags.

**Strata is silent for a long time on first start.** The setup pass downloads the MTP
draft, unpacks it and loads the arena before the port opens — minutes, not seconds. Watch
`podman logs -f strata`; the image's own healthcheck allows a `--start-period=600s` for
exactly this reason.

**Strata dies with a memlock error.** The compose service must run with
`ulimits.memlock: -1` — the arena is page-locked. `podman inspect strata --format
'{{.HostConfig.Ulimits}}'` confirms it.

**"Unable to start: database is locked" on `podman-compose up` with `--build`.** A build
and a running container race on the same image tag; `podman-compose build strata` first,
then `up -d`.

**iGPU model will not load.** Check `free -h` — the Arc allocates against `MemFree`, not
reclaimable `MemAvailable`, so a full page cache looks like exhaustion.

```bash
podman ps
podman logs --tail 30 llama_swap_nvidia
podman logs --tail 30 strata
curl -s 127.0.0.1:8081/v1/models | jq '[.data[]|{id,status:.status.value}]'
curl -s 127.0.0.1:8080/health
nvidia-smi --query-gpu=memory.used,memory.total --format=csv
free -h
```

## Reaching the gateway from a libvirt VM

LiteLLM binds to loopback only:

```bash
sudo iptables -t nat -I PREROUTING -i virbr0 -p tcp --dport 4000 -j DNAT --to-destination 127.0.0.1:4000
sudo sysctl -w net.ipv4.conf.virbr0.route_localnet=1
```
