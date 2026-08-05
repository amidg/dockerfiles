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
| `localhost:8080` | Open WebUI |
| `localhost:8081` | primary GPU, direct to llama-swap |
| `localhost:8082` | secondary GPU (laptop iGPU), direct |
| `localhost:8083` | Intel NPU (experimental, nothing routes here) |

Ports follow **device rank, not machine** — 8081 is the primary GPU on whichever box you
are on. Secrets in `ai/litellm.env`, models in `$LLAMA_MODELS_DIR`.

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
| `local-vision` | `qwen3.6-35b` | `qwen3.6-27b` | images and PDFs |
| `local-tiny` | `qwen3.5-2b` | `gemma-4-12b` | titles, tags, background chores |
| `local-embed` | `embed` | *(not available)* | RAG embeddings, 1024-dim |

```bash
curl -s localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' \
  -d '{"model":"local-main","messages":[{"role":"user","content":"hi"}],"max_tokens":400}'
```

Hardcoding a model name works but breaks on the other machine.

## What runs where (laptop)

| device | port | models | role |
|---|---|---|---|
| RTX 5070 8GB | 8081 | `qwen3.6-35b` (default), `gemma-4-26b`, `qwen3.5-9b` | everything the user waits on |
| Arc Pro iGPU | 8082 | `qwen3.5-2b`, `embed` | background chores + embeddings |
| Intel NPU | 8083 | `Qwen3-1.7B` | experiment only, no traffic |

Only **one** dGPU model is resident at a time. `gemma-4-26b` and `qwen3.5-9b` have no
alias — request them by name, at the cost of a ~15-30s swap.

## Key findings

The short version. Measurements and reasoning are in [`AGENTS.md`](AGENTS.md).

- **A 35B runs on an 8GB card** via `--n-cpu-moe`, which keeps Mixture-of-Experts weights
  (~90% of the file) in system RAM while attention and KV stay on the GPU.
  `qwen3.6-35b` → **411-454 t/s prefill, 31.4 t/s decode, 6947 MiB**.
- **Decode is two different numbers.** Generation from a short prompt is much faster than
  generation continuing from a large one. Judge an agent tier on the latter — it is what a
  Hermes turn actually does.
- **Fewer, faster CPU threads win.** `--threads 6` pinned to the P-cores beats the default
  16 by ~5% and beats 12 or 14 threads by ~40%. Prefill is unaffected.
- **`--n-cpu-moe` does not buy decode at context** — tune it for VRAM headroom instead.
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

**Answers text fine but dies on images.** VRAM headroom too low for the vision encoder.
Raise `--n-cpu-moe` by 1-2 and retest *with an image*.

**Out of VRAM on the dGPU.** Raise `--n-cpu-moe`. For the dense `qwen3.5-9b` instead step
`--ubatch-size` 512 → 384 → 256.

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
