# llama.cpp Tuning & Configuration Guide

Summary of [SteelPh0enix's comprehensive llama.cpp guide](https://blog.steelph0enix.dev/posts/llama-cpp-guide/).

## Quick Start

**Text completion:**
```bash
llama-cli --flash-attn --model model.gguf --prompt "Your prompt here"
```

**Chat mode:**
```bash
llama-cli --flash-attn --model model.gguf --prompt "You are a helpful assistant" --conversation
```

## Core Server Parameters

### Context & Prediction
- **`--ctx-size`** — context window size (tokens the model can "remember"). Higher = more VRAM. Default uses model's training max.
- **`--predict / -n`** — max tokens to generate. `-1` = unlimited, `-2` = use context size.
- **`--batch-size / --ubatch-size`** — tokens fed to the model per step. Defaults usually fine; tweak for VRAM/speed trade-off.

### GPU Acceleration
- **`--gpu-layers / -ngl`** — layers to offload to GPU. Use `99` to load entire model on GPU if it fits.
- **`--split-mode`** & **`--main-gpu`** — control multi-GPU behavior.
- **`--flash-attn`** — Flash Attention optimization. Supported by most modern models; enable by default (no harm if unsupported).

### Memory & Performance
- **`--mlock`** — prevent OS swap by locking model in virtual memory. Speeds up generation but may slow other processes.
- **`--no-mmap`** — disable memory mapping. By default, mmap speeds up loading; disable only if issues occur.
- **`--threads`** — CPU threads. Default `-1` auto-detects; usually don't change.

### Server-Specific
- **`--host`** & **`--port`** — bind address and port.
- **`--alias`** — model name for REST API (default: model filename).
- **`--no-context-shift`** — stop generation when context fills (default: shift oldest tokens out).
- **`--cont-batching`** — enable continuous batching (process prompts in parallel with generation). Enabled by default, improves performance.

## Sampling Parameters

Control how the model picks the next token. Chain of samplers applied in order (e.g., `logits → penalties → top-k → top-p → temperature`).

### Temperature & Randomness
- **`--temp`** — randomness (0.2-2.0 range recommended). Higher = more creative/random, lower = deterministic.
- **`--dynatemp-range`** & **`--dynatemp-exponent`** — Dynamic Temperature: tweaks temperature based on token entropy. Encourages creativity while preventing hallucinations. Often disabled by default; worth testing.

### Token Filtering
- **`--top-k`** — keep only K most probable tokens. Higher = more diversity (default: 40).
- **`--top-p`** — nucleus sampling. Keep tokens with cumulative probability ≥ p (default: 0.95). Set to 0.7 = use top 70% of likely tokens.
- **`--min-p`** — limit tokens based on minimum probability relative to highest. Complements top-p.
- **`--typical-p`** — sort tokens by log-probability vs. entropy difference. Less commonly used.
- **`--xtc-probability`** & **`--xtc-threshold`** — Exclude Top Choices. Sometimes remove most-likely tokens to increase diversity.

### Repetition Control
- **`--repeat-last-n`** — tokens to scan for repetition (default: 64).
- **`--repeat-penalty`** — reduce probability of tokens already in output (default: 1.0 = disabled). Use >1.0 to enable.
- **`--frequency-penalty`** — penalize based on token frequency.
- **`--presence-penalty`** — penalize if token appears at all.
- **`--dry-multiplier`**, **`--dry-base`**, **`--dry-allowed-length`**, **`--dry-penalty-last-n`** — DRY sampler (Decaying Repeated Ngrams): prevents unwanted repetition sequences with exponential penalties.

### Advanced
- **`--mirostat`** — alternative sampler controlling perplexity (entropy). Values: 0=disabled, 1=Mirostat, 2=Mirostat 2.0. Overrides top-k/top-p/typical-p.
- **`--mirostat-lr`** — convergence speed to target perplexity.
- **`--mirostat-ent`** — target entropy/perplexity.

## Backend & Build Options

### GPU Backends (Build-Time)
Compile llama.cpp with:
- **CUDA** — NVIDIA GPUs (fastest on NVIDIA).
- **ROCm** — AMD GPUs (via HIP). May have bugs; Vulkan often more stable.
- **Vulkan** — Generic GPU acceleration (all vendors). Most portable, good performance, recommended for AMD/Intel Arc.
- **SYCL** — Intel oneAPI (Data Center Max, Flex, Arc, iGPUs). Best Intel performance but heavier.
- **OpenBLAS / BLIS / Intel oneMKL** — CPU optimizations.

### CPU Instruction Sets (Build-Time)
Enable in CMake:
- **`GGML_AVX2`** / **`GGML_AVX512`** — standard SIMD (usually auto-enabled).
- **`GGML_AVX_VNNI`** — Intel Alder Lake+ / AMD Zen 5+.
- **`GGML_FMA`** / **`GGML_F16C`** — modern CPU optimizations (auto-enabled if not cross-compiling).
- **`GGML_AMX_TILE`** / **`GGML_INT8`** / **`GGML_BF16`** — Intel Xeon with Advanced Matrix Extensions.

## Intel iGPU / NPU on this laptop

Researched mid-2026 for the Core Ultra 9 285H (Arrow Lake-H, Arc Pro 130T/140T iGPU + NPU).

### iGPU: SYCL over Vulkan

Vulkan is the safe, portable default, but with a current oneAPI runtime + Intel driver, **SYCL
now edges out Vulkan** on Arc iGPUs (community benchmarks show SYCL winning single-stream decode;
Vulkan can still win at high parallel-slot counts). More importantly for this stack: IPEX-LLM's
own docker image (`intelanalytics/ipex-llm-inference-cpp-xpu`, already used for the Ollama stack
in `ai/ollama.yml`) is a vendored llama.cpp fork that lags upstream for brand-new model
architectures. `ghcr.io/mostlygeek/llama-swap:intel` is instead built directly on top of
`ghcr.io/ggml-org/llama.cpp:server-intel-<latest>` — the **official upstream SYCL build** — the
same way `:cuda`/`:rocm`/`:vulkan` already track upstream for the other tiers. That's why
`intel_llama_swap` in `ai/llama-cpp.yml` uses `:intel`, not IPEX-LLM: it gets both the newest
model support and the SYCL performance edge (backend is entirely determined by the image, not by
model `cmd:` flags — so switching backends needs no `cmd:` change at all).

**Measured throughput (2026-07-30, gemma-4-e4b, 6524-token prompt).** The iGPU is bandwidth-bound,
not batch-bound — an 8x `--ubatch-size` increase bought only ~40%, and 2048 actually regresses:

| `--ubatch-size` | prefill | time |
|---|---|---|
| 128 (old 8GB-tier value) | 104 tok/s | 62.5s |
| 512 | 126 tok/s | 51.9s |
| **1024 (current)** | **146 tok/s** | **44.7s** |
| 2048 | 136 tok/s | 48.0s |

Decode sits at ~10 tok/s. Set batches from the *system RAM* budget, not the dGPU's 8GB — the Arc
iGPU has no dedicated VRAM. See `ai/llama-swap-intel.yaml`.

**Debugged gotcha (2026-07-31): looks broken, isn't.** The Intel compute-runtime JIT-compiles
every SYCL kernel variant (attention shapes, flash-attn, KV-cache quant, vision-projector kernels)
on first use, and caches them at `/root/.cache/neo_compiler_cache`. That directory wasn't
persisted, so every container recreate paid the full compile cost again — measured **4m32s** for
the first request after a fresh cache vs. **18s** once warm (SYCL itself was working correctly the
whole time: `llama-server --list-devices` always showed `SYCL0: Intel(R) Arc(TM) Graphics`
detected, and the warm request generated real, correct tokens at ~22 tok/s prompt processing).
Client-side timeouts (LiteLLM, OpenAI SDKs) are commonly shorter than that cold-compile window, so
the first real request after `up` can come back as an empty/failed response even though nothing
is actually misconfigured. Fixed by adding a persistent `intel_sycl_cache` volume at
`/root/.cache` in `ai/llama-cpp.yml`'s `intel_llama_swap` service — kernels now compile once, ever,
per unique shape. If it still looks stuck after that fix, it's real host memory pressure: the Arc
iGPU has no dedicated VRAM, so `llama-server --list-devices`'s reported free memory tracks literal
host `MemFree` (not reclaimable `MemAvailable`) — check `free -h` before assuming a bug.

### NPU: OpenVINO backend (experimental, early-stage)

llama.cpp added an OpenVINO backend in 2026 (`GGML_OPENVINO=ON`) that runs GGUF models on
Intel CPU/GPU/**NPU** through one code path — see
[`docs/backend/OPENVINO.md`](https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/OPENVINO.md).
For the NPU specifically, as of this research:

- **No prebuilt Docker image** — `ghcr.io/ggml-org/llama.cpp` has no `openvino`/`server-openvino`
  tag yet. `.devops/openvino.Dockerfile` also isn't a standalone Dockerfile (it `COPY . .`s the
  whole llama.cpp source tree), so it must be built with the llama.cpp repo itself as build
  context — `intel_npu_llama_server` in `ai/llama-cpp.yml` does this via a git build context
  pinned to a specific commit for reproducibility.
- **No llama-swap integration** — the OpenVINO backend isn't in llama-swap's build matrix, so the
  NPU service runs a single fixed `llama-server` process (no hot-swap, no `llama-swap-config.yaml`
  entry).
- **Stateless only** on NPU (`GGML_OPENVINO_STATEFUL_EXECUTION` is GPU-only), no `--parallel > 1`,
  quantization is Q4_0-oriented (Q4_K/Q5_K/Q6_K get requantized to Q4_0/Q4_0_128 at runtime), and
  small `-c`/context is recommended to avoid OOM (upstream's own example uses `-c 1024`).
- Model: [`bartowski/Qwen_Qwen3-1.7B-GGUF`](https://huggingface.co/bartowski/Qwen_Qwen3-1.7B-GGUF)'s
  plain `Q4_0` quant — Qwen3 is one of the
  [validated model families](https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/OPENVINO.md#validated-models)
  for this backend, and 1.7B dense is small enough to comfortably fit the NPU's tight memory/context
  budget. Q4_0 (not a `_K_`/`_XL` dynamic quant) is what the backend's NPU path expects natively.
  Text-only (no `--mmproj`; OpenVINO backend multimodal support is still in progress).

**Measured 2026-07-30 — it runs, and it is far too slow to use.** Benchmarked against the live
container (`Qwen3-1.7B-Q4_0`, `-c 1024`, NPU):

| metric | NPU (Qwen3-1.7B) | Arc iGPU (gemma-4-e2b) | RTX 5070 (qwen3.5-9b) |
|---|---|---|---|
| decode | **0.61 tok/s** | 16 tok/s | 48 tok/s |
| prefill | 33 tok/s | 194 tok/s | 1932 tok/s |
| 24-token tool call | **39 s** | ~7 s warm | ~2 s |

That is ~21x slower at decode than the iGPU *on a model 2.4x smaller* — roughly 50x slower per
parameter. A generated chat title (~20 tokens) costs ~33s. For reference, this same 1.7B model
would run at 20-40 tok/s on the CPU alone.

Three further findings from that session:

- **Tool calling works.** A `get_weather` probe returned `finish_reason: tool_calls` with correct
  arguments (`{"city": "Berlin"}`). The limitation is throughput, not capability — so "put tool
  calls on the NPU because they're small" fails on latency, not on function. (Separately: tool
  calling is not actually a small-model task. Small models hallucinate arguments and loop, and MCP
  tool schemas alone routinely exceed this backend's 1024-token context.)
- **`-c 1024` is a hard constraint**, and the stateless-only NPU path means no KV reuse across
  turns — every request reprocesses the whole prompt.
- **Thinking models waste the budget.** Qwen3 emits reasoning first; a `max_tokens: 32` request
  spent all 32 tokens in `reasoning_content` and returned empty `content`.

**Verdict: not in the serving path.** The container and the `intel_npu_llama_cpp` profile stay for
experimentation, but no litellm config routes anything to it and no alias resolves to it. The
small/fast workload it was intended for (titles, classification, routing) runs on `gemma-4-e2b` on
the iGPU instead. Note also that the iGPU and NPU share the same LPDDR5x bus as the CPU, so running
both concurrently slows both — they are not independent throughput adders. Revisit once the backend
matures (stateful execution on NPU, parallel requests, broader quant support, a published image).

## Benchmarking

**llama-bench** — measure prompt processing & text generation performance:
```bash
llama-bench --flash-attn 1 --model model.gguf
llama-bench --flash-attn 1 --model model.gguf -pg 1024,256  # mixed prompt+generation
```

Results table:
- `pp512` = prompt processing (512 tokens)
- `tg128` = text generation (128 tokens)
- `t/s` = tokens/sec

## System Prompts

Start conversations with a system prompt to control behavior:
```
You are a helpful assistant.
You are an expert Python programmer.
You are a concise, factual answerer.
```

Quality of the system prompt drastically affects output quality.

## Practical Tuning Tips

1. **Start conservative:** temperature 0.7, top-p 0.95, default batch sizes.
2. **For speed:** enable `--flash-attn`, use full GPU offloading (`-ngl 99`), increase batch sizes.
3. **For quality:** lower temperature (0.3-0.5), reduce top-k/top-p slightly, use dynamic temperature.
4. **For VRAM issues:** reduce `--ctx-size`, lower `--batch-size`, use lower `--gpu-layers`.
5. **Test with llama-bench:** validate performance before full deployment.

## Model Recommendations

- **Small (7B):** Llama 3.1 8B Instruct, Google Gemma 2 9B, Microsoft Phi 3.5
- **Medium (13-14B):** Qwen 2.5 14B, CodeQwen 14B
- **Larger:** Llama 3.1 70B (if VRAM allows)

Find models at [LLM Explorer](https://www.llmexplorer.com/).

## Environment Variables

Most CLI parameters can be set via `LLAMA_ARG_*` environment variables. Example:
```bash
export LLAMA_ARG_THREADS=8
export LLAMA_ARG_N_GPU_LAYERS=99
export LLAMA_ARG_FLASH_ATTN=1
llama-server --model model.gguf
```

## Integration with llama-swap

When using **llama-swap** (model hot-swapping proxy):
- Configure `cmd:` to include performance tuning flags.
- Example:
  ```yaml
  "gemma-4-26b":
    cmd: >
      /app/llama-server
      --model /models/gemma-4-26B.gguf
      --host 127.0.0.1 --port ${PORT}
      -ngl 99 --ctx-size 4096 --flash-attn --temp 0.7
    proxy: "http://127.0.0.1:${PORT}"
    ttl: 300
  ```

---

**Source:** [SteelPh0enix - llama.cpp guide](https://blog.steelph0enix.dev/posts/llama-cpp-guide/) (Updated: 2024-12-25)
