# Local LLM stack — llama.cpp + llama-swap + LiteLLM

Self-hosted inference for the Hermes agent across two machines. One OpenAI-compatible
endpoint, stable model aliases, per-machine hardware config behind them.

This file is **how to run it**. For why anything is tuned the way it is — and the traps
that cost hours — read [`AGENTS.md`](AGENTS.md).

## Run it

```bash
export LLAMA_MODELS_DIR=/mnt/data/llama/models     # where the GGUFs live

# laptop: RTX 5070 + Arc iGPU, both at once
podman-compose -f ai/llama-cpp.yml --profile laptop up -d

# desktop: 7900 XTX
podman-compose -f ai/llama-cpp.yml --profile amd_llama_cpp up -d
```

LiteLLM needs ~30-60s. Poll before sending traffic:

```bash
curl -s localhost:4000/health/liveliness
```

| endpoint | what |
|---|---|
| `localhost:4000/v1` | LiteLLM gateway — **point agents here** |
| `localhost:4000/ui` | admin (log in with `LITELLM_MASTER_KEY`) |
| `localhost:3000` | Open WebUI |
| `localhost:8081` | laptop primary GPU (RTX 5070), direct to llama-swap |
| `localhost:8082` | laptop secondary GPU (Arc iGPU), direct |
| `localhost:8083` | Intel NPU (experimental, nothing routes here) |
| `localhost:8080` | desktop llama-swap (7900 XTX), direct |

Secrets in `ai/litellm.env`, models in `$LLAMA_MODELS_DIR`.

## Architecture

```
agents ──> LiteLLM :4000 ──┬──> llama-swap :8081 ──> llama-server (primary GPU)
           (aliases,       │
            fallbacks,     └──> llama-swap :8082 ──> llama-server (iGPU, laptop only)
            cloud models)
```

LiteLLM resolves a **semantic alias** to a model and forwards to the llama-swap instance
that owns it. llama-swap spawns and kills one `llama-server` per model on demand, and
unloads after an idle TTL. Cloud models (Anthropic, Gemini) route through the same
gateway.

## Use the aliases, not model names

The names are identical on both machines — that is what lets one shared
`~/.hermes/config.yaml` drive either box. Only the model behind each name changes.

| alias | laptop | desktop | for |
|---|---|---|---|
| `local-main` | `qwen3.6-35b` | `qwen3.6-27b` | main agent, delegation, anything user-facing |
| `local-vision` | `gemma-4-e2b` (iGPU) | `qwen3.6-27b` | images and PDFs |
| `local-tiny` | `gemma-4-e2b` | `gemma-4-12b` | titles, tags, background chores |
| `local-embed` | *(currently unwired)* | *(not available)* | RAG embeddings, 1024-dim |

```bash
curl -s localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' \
  -d '{"model":"local-main","messages":[{"role":"user","content":"hi"}],"max_tokens":400}'
```

Hardcoding a model name works but breaks on the other machine.

## What runs where (laptop)

| device | port | models | role |
|---|---|---|---|
| RTX 5070 8GB | 8081 | `qwen3.6-35b` (default, MTP), `qwen3.6-35b-128k`, `gemma-4-26b` | everything the user waits on |
| Arc Pro iGPU | 8082 | `gemma-4-e2b` (vision), `gemma-4-e4b`, `qwen3.5-2b`, `qwen3.5-4b` | background chores + vision |
| Intel NPU | 8083 | `Qwen3-1.7B` | experiment only, no traffic |

Only **one** dGPU model is resident at a time. `qwen3.6-35b-128k` and `gemma-4-26b` have no
alias — request them by name, at the cost of a ~15-30s swap.

## Key findings

The short version. Measurements and reasoning are in [`AGENTS.md`](AGENTS.md).

- **A 35B runs on an 8GB card** via `--n-cpu-moe`, which keeps Mixture-of-Experts weights
  (~90% of the file) in system RAM while attention and KV stay on the GPU.
  `qwen3.6-35b` → **1329 t/s prefill, 47.6 t/s decode, 7305 MiB**.
- **Need more than 64K?** Request `qwen3.6-35b-128k` by name. Doubling the window is free;
  the VRAM it forces you to buy costs ~7% of everyday decode, and TTFT at 118K is 133s —
  which is why it is a separate entry rather than the default.
- **Q4_K_M is the quant floor here.** Both a smaller K-quant (Q3_K_XL) and an i-quant
  (IQ4_XS) lose on decode despite reading fewer bytes: dequantisation cost on this
  AVX2-only CPU outweighs the saving.
- **MTP is the biggest single win on this box: 1.53x decode at 6.5K, 2.59x at 58K.**
  Published MoE figures (1.17-1.40x) badly understate it, because they were measured on
  fully-GPU-resident models that had no batching slack left. With experts on the CPU there
  is a 14x gap between prefill and batch-1 decode, and MTP collects it. Use
  `--spec-draft-n-max 2`; **3 is not lossless on this build**.
- **`--ubatch-size 2048` triples dGPU prefill** (410 → 1323 t/s) at no decode cost. The old
  512 was inherited from the iGPU, where the opposite is true.
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
- **`--n-cpu-moe` is cheap without MTP and expensive with it** — 4 layers cost ~7% of decode
  on the promoted config. Buy VRAM headroom from `--ubatch-size` first.
- **Splitting the model across both GPUs with Vulkan was tested and rejected**: the iGPU
  does beat the CPU at expert work (+24%), but leaving CUDA for Vulkan costs 67% first.
- **Text tests will not catch a vision crash.** Always send a real image after retuning.
- **At the small end, prefer dense over MoE** — expert gathers are inefficient on the Arc.

## Check it works

The benchmark harness lives in a separate repo:
[amidg/llm-benchmarking](https://github.com/amidg/llm-benchmarking).

```bash
git clone git@github.com:amidg/llm-benchmarking.git
cd llm-benchmarking
export LITELLM_ENV=~/Projects/dockerfiles/ai/litellm.env

./smoke.py          # every tier, every alias, vision, approval shape
./smoke.py --quick  # just show what is loaded where

./llmbench.py --models qwen3.6-35b gemma-4-26b --tests all
```

## Files

| file | what |
|---|---|
| `llama-cpp.yml` | compose: llama-swap instances, LiteLLM, Open WebUI, postgres |
| `llama-swap-nvidia.yaml` | laptop primary GPU |
| `llama-swap-intel.yaml` | laptop secondary GPU (iGPU) |
| `llama-swap-config.yaml` | desktop 7900 XTX |
| `litellm-config.laptop.yaml` | laptop gateway: aliases, fallbacks, cloud models |
| `litellm-config.desktop.yaml` | desktop gateway — same alias names, different models |
| `litellm.env` | secrets (gitignored) |
| `AGENTS.md` | **rules, rationale, learnings — read before editing any config** |

Configs deliberately carry **no comments**; all rationale lives in `AGENTS.md`.
`ollama.yml`, `n8n.yml`, `research.yml`, `firecrawl.yaml` are separate stacks.

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

**Answers text fine but dies on images.** The dGPU tier runs `--no-mmproj` by design —
vision lives on the iGPU as `local-vision` → `gemma-4-e2b`. A dGPU model rejecting an image
is correct behaviour, not a fault.

**Out of VRAM on the dGPU.** Drop `--ubatch-size` (2048 → 1024) *before* raising
`--n-cpu-moe`. With MTP, N costs ~7% of decode per 4 layers while prefill has 3x of margin.

**iGPU model will not load.** Check `free -h` — the Arc allocates against `MemFree`, not
reclaimable `MemAvailable`, so a full page cache looks like exhaustion.

```bash
podman ps
podman logs --tail 30 llama_swap_nvidia
curl -s 127.0.0.1:8081/v1/models | jq '[.data[]|{id,status:.status.value}]'
nvidia-smi --query-gpu=memory.used,memory.total --format=csv
```

## Reaching the gateway from a libvirt VM

LiteLLM binds to loopback only:

```bash
sudo iptables -t nat -I PREROUTING -i virbr0 -p tcp --dport 4000 -j DNAT --to-destination 127.0.0.1:4000
sudo sysctl -w net.ipv4.conf.virbr0.route_localnet=1
```
