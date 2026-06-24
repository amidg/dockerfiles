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
