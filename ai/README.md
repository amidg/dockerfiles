# Local LLM stack — llama.cpp + llama-swap (laptop) / Strata (desktop) + strata-poly (laptop) + LiteLLM

Self-hosted inference for the Hermes agent across two machines. One OpenAI-compatible
endpoint, stable model names, per-machine engine behind them.

This file is **how to run it**. For why anything is tuned the way it is — and the traps
that cost hours — read [`AGENTS.md`](AGENTS.md).

## Run it

```bash
export LLAMA_MODELS_DIR=/var/mnt/data/llama/models   # where the GGUFs live
export STRATA_DATA_DIR=/var/mnt/data/llama/strata    # same path on both machines: the engine's /data

# laptop: strata-poly + Arc iGPU + LiteLLM (the RTX 5070 llama-swap is manual:
# --profile nvidia_llama_cpp; it is no longer part of the laptop profile)
podman-compose -f ai/llama-cpp.yml --profile laptop up -d --build

# desktop: 5070 Ti 16GB — builds and runs Strata (Swift 1.5 IQ2_XS)
podman-compose -f ai/llama-cpp.yml --profile server up -d --build
```

Both `--build` flags compile their engine from the pinned submodule on first use (and
after any submodule bump): `ai/Strata` for the desktop, `ai/PolyStrata` for the laptop
(the in-repo `polystrata.Dockerfile` adds the `strata-poly` build upstream's own image
lacks). LiteLLM needs ~30-60s. Poll before sending traffic:

```bash
curl -s localhost:4000/health/liveliness
```

| endpoint | what |
|---|---|
| `localhost:4000/v1` | LiteLLM gateway — **point agents here** |
| `localhost:4000/ui` | admin (log in with `LITELLM_MASTER_KEY`) |
| `localhost:8081` | laptop primary GPU (RTX 5070), direct to llama-swap — only with `--profile nvidia_llama_cpp` |
| `localhost:8082` | laptop secondary GPU (Arc iGPU), direct |
| `localhost:8083` | whisper-pro ASR (Intel iGPU) — STT |
| `localhost:8080` | desktop Strata (5070 Ti) / laptop strata-poly (RTX 5070), direct — **no auth, LAN-reachable** |

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
| context | 262144 |
| KV | `k8v4` |
| vision | **cpu** — the engine only recommends the GPU encoder at ≥23.5GB VRAM (upstream #2406); on 16GB the CPU encoder frees ~1.1-1.4GB for the expert cache at a 3-5% decode cost |
| model name | `qwen3.8-flash-next` (LiteLLM → `http://strata:8080/v1`) — deliberately names the Swift weights |

**Measured 2026-10-18** (first real run; full write-up in
[`reports/strata-report-2026-10-18.md`](reports/strata-report-2026-10-18.md)):
**2036 t/s prefill, 113.5 t/s deep decode**, tools 4/4, quality 4/4, a 50K-token needle in
20.9 s, vision correct on real 1280px images (~3 s each) — roughly **3× the laptop's main
model on deep decode**, with LiteLLM adding no measurable cost. Arena 33.0 GiB of the
40 GiB pin; warm restart 20 s.

**Context raised to 262144 on 2026-10-19** (KV is only 13 × 816 B/token here, so the whole
window adds 2.6 GiB of pinned RAM and no VRAM): a **197 451-token prompt is fully read in
61 s** with the needle found and decode still 132-156 t/s at that depth; perf at ~8.6K is
unchanged (2041 t/s prefill, 107.4 t/s deep).

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

## Laptop: strata-poly + Tiel Coder 35B (`strata`)

The laptop's second inference engine: **strata-poly** (`ai/PolyStrata`, pinned to
`v0.1.45-poly.1`), PolyStrata's engine for models that read their GGUF in place with a
VRAM expert cache. It runs **Tiel Coder 35B-A3B UD-Q3_K_XL** — the same GGUF and projector
the llama.cpp entry uses — as a resident container named **`strata`**, and the gateway name
`tiel-coder-35b` routes to it. **Since 2026-10-20 the `laptop` profile starts strata-poly +
the Arc iGPU + LiteLLM only**: the RTX 5070 llama-swap (tiel fallback, gemma) is manual
(`--profile nvidia_llama_cpp`), and the gemma entries were removed from
`litellm-config.laptop.yaml` for now. **The desktop's container is `strata` too** — the same name,
the same data path, on a different machine and a **different engine** (Niko1221/Strata,
which serves `qwen4exp` only); the two never meet, and the laptop's compose **service key**
is `strata_laptop` because one compose file cannot hold two services of the same name.

| | |
|---|---|
| GPU | RTX 5070 Laptop 8GB (`CUDA_ARCHITECTURES=120`) |
| RAM | ~21 GB expert working set of 62GB — no arena pin; the engine pins memory, so `ulimits.memlock: -1` is mandatory |
| SSD | `${STRATA_DATA_DIR:-/var/mnt/data/llama/strata}` → `/data:z` (tokenizer pack, expert profile, config) — the same path name as the desktop |
| context | 131072 |
| KV | setup.py's default (`int8`) |
| vision | **cpu** — setup puts the encoder on the CPU below 16GB VRAM; seconds per image |
| model name | `tiel-coder-35b` (LiteLLM → `http://strata:8080/v1`); the engine advertises `tiel-coder-35b-a3b-ud-q3_k_xl` and serves any requested name |

Upstream's own image builds only the Qwen `strata` engine, so the in-repo
`ai/polystrata.Dockerfile` adds the `strata-poly` + CPU-`strata-vision` builds using
setup.py's own build helpers; the first start finds `engine-poly/BUILD.json` current and
goes straight to loading the model.

**Weights are already on disk — no download.** `Tiel-Coder-35B-A3B-MTP-UD-Q3_K_XL.gguf`
(17.2GB, pinned SHA-256 `46b8fbeb…`) and the projector (0.9GB). setup.py looks for the
projector under **its original name**, `$LLAMA_MODELS_DIR/mmproj-BF16.gguf`; the llama.cpp
entry mounts the same inode as `tiel-coder-35b-mmproj-BF16.gguf`. Link it once (0 bytes,
after checking SHA-256 `d9ce3102…`):

```bash
ln /mnt/data/llama/models/tiel-coder-35b-mmproj-BF16.gguf /mnt/data/llama/models/mmproj-BF16.gguf
```

Without the link setup downloads its own 0.9GB copy. The separate MTP head file is **not**
used by poly (its draft block ships inside the GGUF) — it exists for the llama.cpp fallback
entry.

**Free the card before the first start.** llama-swap's resident tiel holds ~7.3GB of the
8GB, so stop it first (it also hands back ~18GB of RAM):

```bash
cd ~/Projects/dockerfiles
git pull --ff-only
git submodule update --init --checkout ai/PolyStrata
mkdir -p /var/mnt/data/llama/strata
podman-compose -f ai/llama-cpp.yml --profile laptop stop nvidia_llama_swap
podman-compose -f ai/llama-cpp.yml --profile laptop build strata_laptop   # compose takes the service key
podman-compose -f ai/llama-cpp.yml --profile laptop up -d strata_laptop
podman logs -f strata   # minutes of expected silence: tokenizer pack, config, model load
```

A later blanket `--profile laptop up -d` also starts `nvidia_llama_swap`; keep it stopped
(or unload poly first) — see co-residency below.

First-boot checks, in order: `curl -s 127.0.0.1:8080/health`; the log reports the RTX 5070
(same podman CDI fallback as the desktop); `/v1/models` (informational — the LiteLLM entry
keeps `tiel-coder-35b`); a completion from inside the LiteLLM container (a `403 ... not
allowed` means `STRATA_ALLOWED_HOSTS` lost its entry); a **real 1280px image**; the gateway
after ~30-60s; `free -h` ≈ 22GB in use with the model resident.

**Co-residency: unload strata-poly before any llama-swap load.** While strata-poly is
resident it holds ~7-8GB of the card, so `gemma-4-26b-a4b`, `gemma-4-e4b`, and the
llama.cpp `tiel-coder-35b` fallback all need `curl -s -X POST -H 'Content-Type: application/json' -d '{}' 127.0.0.1:8080/api/models/unload`
first; llama-swap cannot call it. The reverse direction is the same: unload `:8081` before
a request to `:8080`. The llama.cpp tiel entry stays wired as the manual fallback, reachable
direct on `:8081/v1`.

**Measured and promoted (2026-10-19), same-session A/B, `llmbench.py --tests all --rounds 3`:**

| | strata-poly (`:8080`) | llama.cpp (`:8081`) |
|---|---|---|
| prefill (r1) | **1704 t/s** | 1638 t/s |
| decode (shallow) | **59.7 t/s** | 26.7 t/s |
| deep | **51.2 / 63.3 / 65.1** | 32.6 / 34.5 / 33.5 |
| 50K longctx | 50,173 @ 1338 t/s (37.5 s) | 49,968 @ 1451 t/s (34.4 s) |
| tools / quality / approval | 4/4 / 4/4 / PASS | 4/4 / 4/4 / PASS |
| vision | yes (real 1280px: `PLATYPUSS`, 7.6 s) | yes (`PLAYYUUS`) |

Deep decode is **~90% faster** (63-65 vs 33-34 t/s) at equal correctness; prefill is a tie
and long-context ingest is ~8% slower. Absolute values drift 20-30% with thermals — compare
within one session only (the incumbent's 2026-10-18 baseline was 40.1 deep; today's same-run
number is 33.5). VRAM 7544 MiB at load, ~29GB system RAM, first boot ~30s.

## Whisper ASR (Intel iGPU + diarization)

Local speech-to-text on a **locally built** Intel-only image
(`localhost/whisper-pro-asr:intel-whisperx`), running **large-v3-turbo** on the **iGPU** with
speaker diarization via WhisperX/PyAnnote. It lives in its own stack, `ai/whisper.yml`
(service `whisper_igpu`), joined to the llama-swap network. Host `:8083` → container `:9000`.

The image is `ai/Containerfile.whisper_intel` built against the pinned upstream checkout
`ai/Whisper-Pro-ASR` (submodule): upstream's `intel` target plus the WhisperX libs, minus the
CUDA/ROCm stages and NVIDIA/AMD ONNX Runtime wheels that make their `full` target ~30 GB.
The build is **4.7 GB on disk** (measured) and is a superset of the old `intel` image.

```bash
podman-compose -f ai/whisper.yml --profile whisper_igpu up -d --build
```

Weights are not downloaded by the container — the large-v3-turbo OpenVINO IR is bind-mounted
read-only from `$LLAMA_MODELS_DIR/whisper-openvino` to `/app/system_models/whisper-openvino`,
which whisper-pro prefers when present (otherwise it downloads its own OpenVINO large-v3 and
the first start waits in the queue). Fetch it with:

```bash
hf download OpenVINO/whisper-large-v3-turbo-fp16-ov \
  --local-dir /mnt/data/llama/models/whisper-openvino
```

| endpoint | what |
|---|---|
| `localhost:8083` | whisper-pro ASR server (direct, no auth) |
| `localhost:4000/v1`, model `whisper` | via LiteLLM — **what Hermes STT uses** |

Direct (no auth, `response_format` = `json` / `srt` / `segments`; add `diarize=true` for
speaker labels):

```bash
curl -s http://localhost:8083/v1/audio/transcriptions \
  -F "file=@/path/to/audio.mp3" -F "model=whisper-large-v3" -F "response_format=json" \
  -F "diarize=true"
```

LiteLLM maps alias `whisper` → `http://whisper_server_igpu:9000/v1`
(`model_info: mode: audio_transcription`, container-internal port — **not** the host
`:8083`). Hermes is wired to it via `stt.provider: openai`,
`stt.openai.base_url: http://localhost:4000/v1`, `stt.openai.model: whisper`.

**Diarization needs `DIARIZATION_HF_TOKEN`** in `ai/whisper.env` (gitignored, mounted by
`whisper_igpu`). The account must have accepted all three gated pyannote repos listed in that
file's header. Empty/missing = diarization is skipped gracefully and plain transcription runs.
PyAnnote runs on the CPU torch build in this image; the ASR itself is on the iGPU.

**NPU is available but not the ASR device.** `base_npu` also maps `/dev/accel`, and
`ASR_PREPROCESS_DEVICE=NPU` sends vocal isolation there; `ASR_DEVICE=GPU` keeps Whisper on the
Arc. Turbo on the iGPU is both faster and more accurate than small-int4 on the NPU, which is
why the old NPU service was retired. `VERIFY_RUNTIME=false` is kept for the NPU paths (the
gate rejects every dynamic OpenVINO IR, which OpenVINO 2026.3.1 executes fine).

**UVR is the trap.** UVR = **Ultimate Vocal Remover** — a source-separation model
(MDX-NET) that strips background music/noise and keeps only the vocals *before*
transcription. whisper-pro can run it on the iGPU/NPU, and by default it ran **twice** per
request (once in the main pipeline, once inside language-detection preprocessing), adding
~25 s each. That, not the ASR, was the slowness. For clean voice input UVR buys nothing, so
both passes are off:

| env | default | here | controls |
|---|---|---|---|
| `ENABLE_VOCAL_SEPARATION` | `true` | `false` | the main UVR pass |
| `ENABLE_LD_PREPROCESSING` | `true` | `false` | the LD UVR pass (the sneaky second one) |

Re-enable both only for music-heavy source material.

### Model, and why the iGPU (research)

**large-v3-turbo on the iGPU.** Turbo is a distilled large-v3 (4 decoder layers), so it is
both faster and noticeably more accurate than the int4 small model the NPU used to serve.
The NPU gate is bypassed with `VERIFY_RUNTIME=false` (it only skips the static-shape probe,
the engine's NPU warm-up, and a startup ONNX-diagnostics log); `ASR_DEVICE=GPU` pins the iGPU.

Measured on a 60 s clip (laptop):

| model | device | build | inference (60 s) |
|---|---|---|---|
| small-int4 | NPU | 21.5 s | 4.8 s |
| small-int4 | iGPU | 6.5 s | 7.0 s |
| small-int4 | CPU | 0.7 s | 6.7 s |
| large-v3-turbo-fp16 | NPU | 179 s | 8.2 s |
| **large-v3-turbo-fp16** | **iGPU** | 6.2 s | **4.4 s** |
| large-v3-turbo-fp16 | CPU | 0.6 s | 26.8 s |

End-to-end through the service (warm): **~5.1 s per 60 s clip** on the former NPU setup
(inference ~4.2 s) and **54 s for the full 10-minute video**; the first request after a
container recreate adds the NPU compile. On the iGPU the same clip takes **4.4 s** and
turbo's compile is ~6.2 s — that is why the iGPU is now the ASR device.

### Residency and cold starts

By default the model is unloaded **300 s after the last request** (`MODEL_IDLE_TIMEOUT=300`).
The service sets **`MODEL_IDLE_TIMEOUT=0`**, keeping the model resident for the container's
lifetime, plus **`restart: unless-stopped`** so a reboot/crash does not need a manual `up`.
Only an actual container recreate (config edit, image update) pays the model compile again:
**~6 s** for large-v3-turbo on the iGPU. On the NPU the same reload costs ~21 s (small-int4)
to ~179 s (turbo), because the NPU never caches its compiled blob — another reason the ASR
device moved to the iGPU.

## Architecture

```
agents ──> LiteLLM :4000 ──┬──> llama-swap :8081 ──> llama-server (laptop primary GPU)
           (model names,    │
            routing)        └──> llama-swap :8082 ──> llama-server (laptop iGPU)

agents ──> LiteLLM :4000 ──> strata-poly :8080       (laptop, RTX 5070, resident)
agents ──> LiteLLM :4000 ──────> Strata :8080        (desktop, 5070 Ti)
```

LiteLLM forwards a requested model name to whichever engine owns it. On the laptop,
llama-swap spawns and kills one `llama-server` per model on demand and unloads after an
idle TTL; strata-poly is one long-resident process, as on the desktop. **The 8GB card is
shared: only one of the two dGPU engines can hold it at a time** — unload strata-poly
(`POST :8080/api/models/unload` with a JSON body: `-H 'Content-Type: application/json' -d '{}'`)
before llama-swap loads anything, and unload llama-swap
(`POST :8081/api/models/unload`) before a request to strata-poly.

## Use the model names

Direct names, no aliases. The laptop and the desktop serve different names — a shared
`~/.hermes/config.yaml` points at whichever box it is talking to.

| name | machine | engine | for |
|---|---|---|---|
| `qwen3.8-flash-next` | desktop | Strata, 5070 Ti, 262K, Swift 1.5 weights | main agent, delegation, vision (CPU encoder), anything user-facing |
| `tiel-coder-35b` | laptop | **strata-poly** (resident), RTX 5070, 131K, Q3_K_XL, vision on CPU | **default agent, delegation, aux tasks, vision** — LiteLLM routes it to `strata:8080` from 2026-10-19; the llama.cpp entry on `:8081` (MTP, N=35, 40.1 t/s deep, 1442 t/s prefill) stays as the manual fallback |
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
| RTX 5070 8GB | 8080 | `strata-poly` → `tiel-coder-35b` (resident, 131K, UD-Q3_K_XL, vision on CPU) | the default agent path, from 2026-10-19 |
| RTX 5070 8GB | 8081 | llama-swap: `tiel-coder-35b` (MTP, vision on CPU, 131K, ttl 0 — **manual fallback**), `gemma-4-26b-a4b` (MTP, vision, 131K, on-demand), `gemma-4-e4b` (MTP, vision, 128K, on-demand) | the llama.cpp tier; everything the user waits on while strata-poly is unloaded |
| Arc Pro iGPU | 8082 | `embeddinggemma-2` (embeddings) | embeddings |
| Intel iGPU | 8083 | `large-v3-turbo-fp16` (whisper-pro ASR) | STT — iGPU inference + diarization, UVR off |

Only **one** dGPU engine is resident at a time: strata-poly holds the card until
`POST :8080/api/models/unload`, and any llama-swap load evicts everything else (~15-30s
swap, which llama-swap cannot initiate against strata-poly).

### Weights on the laptop (manual, into `$LLAMA_MODELS_DIR`)

- `gemma-4-26B-A4B-it-qat-UD-Q4_K_XL.gguf` (14.25GB), `mmproj-F16.gguf` (1.19GB — the
  projector, from the same `gemma-4-26B-A4B-it-qat-GGUF` repo) and
  `mtp-gemma-4-26B-A4B-it.gguf` (252MB) — the main dGPU model. Verify sha256 after
  downloading; a truncated GGUF fails at load, not at download.
- `gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf` + `gemma-4-e4b-qat-mmproj-F16.gguf` +
  `mtp-gemma-4-E4B-it.gguf` — the on-demand fallback.
- `Tiel-Coder-35B-A3B-MTP-UD-Q3_K_XL.gguf` (17.2GB) + `mmproj-BF16.gguf` (903MB, from the
  `peculiar-ragdoll/Tiel-Coder-35B-A3B-GGUF-MTP` repo) — **strata-poly's model**: setup
  matches these names exactly and verifies SHA-256 against its pinned revision, so keep
  them as downloaded. The GGUF carries its own draft block, so no separate MTP file is
  used by poly. `tiel-coder-35b-mmproj-BF16.gguf` is the same projector under the name
  the llama.cpp fallback entry mounts.
- `Qwen3.6-35B-A3B-UD-Q3_K_XL.gguf` (17.2GB) + `qwen3.6-35b-mmproj-F16.gguf` (899MB) —
  **kept on disk, unwired**: lost the 2026-10-18 A/B to tiel (agentic task time, image OCR).
  To re-test, add a llama-swap entry; nothing else needs to change.
- `embeddinggemma-2-Q8_0.gguf` — embeddings, the only iGPU model.
- Deleted 2026-10-18 (re-downloadable if ever wanted back): the Tiel-Coder-35B and both
  LFM2.5-24B GGUFs.

## What runs where (desktop)

| device | port | model | role |
|---|---|---|---|
| 5070 Ti 16GB | 8080 | `qwen3.8-flash-next` (Strata, Swift 1.5 IQ2_XS, 262K, vision on CPU, `k8v4` KV) | everything — the only inference engine on the box |
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
| `PolyStrata/` | git submodule — the laptop's strata-poly engine (pinned release tag) |
| `polystrata.Dockerfile` | the in-repo PolyStrata image: adds the `strata-poly` + CPU-encoder builds upstream's image lacks |
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

**Strata is silent for a long time on first start** (`strata` on both machines). The setup
pass fetches/unpacks what it needs (the desktop's MTP draft and pack; the laptop's tokenizer
pack) and loads the model before the port opens — minutes, not seconds. Watch
`podman logs -f strata`; both images' healthcheck allows a `--start-period=600s` for
exactly this reason.

**Strata dies with a memlock error.** Both services must run with `ulimits.memlock: -1` —
the desktop arena and the laptop's poly working set are both pinned. `podman inspect
strata --format '{{.HostConfig.Ulimits}}'` confirms it.

**"Unable to start: database is locked" on `podman-compose up` with `--build`.** A build
and a running container race on the same image tag; `podman-compose build strata` first,
then `up -d`.

**iGPU model will not load.** Check `free -h` — the Arc allocates against `MemFree`, not
reclaimable `MemAvailable`, so a full page cache looks like exhaustion.

**llama-swap loads fail while `strata` (strata-poly) is resident.** Not a bug — two engines,
one 8GB card. Unload strata-poly (`curl -s -X POST -H 'Content-Type: application/json' -d '{}' 127.0.0.1:8080/api/models/unload`) before
any llama-swap model loads, and unload llama-swap (`POST 127.0.0.1:8081/api/models/unload`)
before a request to `:8080`.

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
