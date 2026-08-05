# Local LLM stack — llama.cpp + llama-swap + LiteLLM

Self-hosted inference for the Hermes agent across two machines. One OpenAI-compatible endpoint
(`localhost:4000`), stable model aliases, and per-machine hardware config behind them.

For the *why* behind every tuning decision — and the traps that cost hours — read
[`AGENTS.md`](AGENTS.md). This file is just how to run it.

## Quick start

```bash
export LLAMA_MODELS_DIR=/mnt/data/llama/models          # where the GGUFs live

# laptop: RTX 5070 + Arc iGPU concurrently
podman-compose -f ai/llama-cpp.yml --profile laptop up -d

# desktop: 7900 XTX
podman-compose -f ai/llama-cpp.yml --profile amd_llama_cpp up -d
```

LiteLLM needs ~30-60s to become ready. Poll before sending traffic:

```bash
curl -s localhost:4000/health/liveliness
```

| endpoint | what |
|---|---|
| `localhost:4000/v1` | LiteLLM gateway — **point agents here** |
| `localhost:4000/ui` | LiteLLM admin (log in with `LITELLM_MASTER_KEY`) |
| `localhost:8080` | Open WebUI |
| `localhost:8081` | primary GPU, direct to llama-swap |
| `localhost:8082` | secondary GPU (laptop iGPU), direct |
| `localhost:8083` | Intel NPU (experimental, nothing routes here) |

Ports follow **device rank, not machine**: 8081 is always the primary GPU, whichever box you are
on. Secrets live in `ai/litellm.env`; models in `$LLAMA_MODELS_DIR`.

## Use the aliases, not model names

Agents should target these. The names are identical on both machines — that is what lets one
shared `~/.hermes/config.yaml` drive either box. Only the model behind each name changes.

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

Hardcoding a model name works but breaks the moment you run the same config on the other machine.

## What runs where (laptop)

| device | port | models | role |
|---|---|---|---|
| RTX 5070 8GB | 8081 | `qwen3.6-35b` (default), `gemma-4-26b`, `qwen3.5-9b` | everything the user waits on |
| Arc Pro iGPU | 8082 | `qwen3.5-2b`, `embed` | background chores + embeddings |
| Intel NPU | 8083 | `Qwen3-1.7B` | experiment only, no traffic |

The 26B and 35B models run on an 8GB card via `--n-cpu-moe`, which keeps Mixture-of-Experts weights
(~90% of the file) in system RAM while attention and the KV cache stay on the GPU.

Only **one** dGPU model is resident at a time. `gemma-4-26b` and `qwen3.5-9b` have no alias —
request them by name, at the cost of a ~15-30s swap.

### Picking a main model

| model | prefill | decode | trivial Hermes turn |
|---|---|---|---|
| `qwen3.6-35b` **(default)** | 395 tok/s | 14.9 tok/s | ~60s |
| `gemma-4-26b` | 616 tok/s | 17.9 tok/s | ~39s |
| `qwen3.5-9b` | 1932 tok/s | 48 tok/s | ~2.6s |

The default is **not** the fastest — it trades latency for a 35B-class model. To prefer speed,
change `local-main` and `local-vision` in `ai/litellm-config.laptop.yaml`:

```yaml
model_group_alias:
  local-main: gemma-4-26b
  local-vision: gemma-4-26b
```

then `podman restart litellm`. Nothing else needs to change — that is the point of the alias layer.

## Files

| file | what |
|---|---|
| `llama-cpp.yml` | compose: llama-swap instances, LiteLLM, Open WebUI, postgres |
| `llama-swap-nvidia.yaml` | laptop primary GPU — model definitions + tuning |
| `llama-swap-intel.yaml` | laptop secondary GPU (iGPU) |
| `llama-swap-config.yaml` | desktop 7900 XTX |
| `litellm-config.laptop.yaml` | laptop gateway: aliases, fallbacks, cloud models |
| `litellm-config.desktop.yaml` | desktop gateway — same alias names, different models |
| `litellm.env` | secrets (gitignored) |
| `bench/smoke.py` | health-check every tier and alias; exits non-zero on failure |
| `bench/llmbench.py` | compare models: throughput, tool use, quality, long context, vision |
| `AGENTS.md` | **tuning rationale and gotchas — read before editing anything above** |
| `LLAMA-CPP.md` | llama.cpp flag reference + Intel iGPU/NPU research |

`ollama.yml`, `n8n.yml`, `research.yml` are separate stacks that predate this one.

## Checking it works

```bash
ai/bench/smoke.py          # every tier, every alias, vision, and the approval shape
ai/bench/smoke.py --quick  # just show what is loaded where
```

To compare models (throughput, tool use, quality, long context):

```bash
ai/bench/llmbench.py --models qwen3.6-35b gemma-4-26b --tests all
```

See `ai/bench/README.md` for what each test catches and how to read the numbers.

## Troubleshooting

**Empty response right after `up`.** Either LiteLLM is still starting (~30-60s — poll
`/health/liveliness`), or the Arc iGPU is JIT-compiling SYCL kernels on a cold cache. The latter
took 4m32s once; the `intel_sycl_cache` volume makes it a one-time cost.

**Blank `content` with a filled `reasoning_content`.** These are thinking models and the budget ran
out before the answer. Not a failure — raise `max_tokens` to 400+.

**A model answers text fine but dies on images.** VRAM headroom too low for the vision encoder.
Raise `--n-cpu-moe` by 1-2 and retest *with an image* — text-only tests pass in exactly the
configurations that crash.

**Out of VRAM on the dGPU.** Raise `--n-cpu-moe` (moves experts to RAM; costs decode speed, leaves
context alone). For the dense `qwen3.5-9b` instead step `--ubatch-size` 512 → 384 → 256.

**iGPU model will not load.** Check `free -h`. The Arc iGPU allocates against `MemFree`, not
reclaimable `MemAvailable`, so a full page cache can look like exhaustion.

```bash
podman ps                                                     # what is up
podman logs --tail 30 llama_swap_nvidia                       # or llama_swap_intel / litellm
curl -s localhost:8081/v1/models | jq '[.data[]|{id,status:.status.value}]'
nvidia-smi --query-gpu=memory.used,memory.total --format=csv
```

## Reaching the gateway from a libvirt VM

LiteLLM binds to loopback only. To let VMs on `virbr0` reach it:

```bash
sudo iptables -t nat -I PREROUTING -i virbr0 -p tcp --dport 4000 -j DNAT --to-destination 127.0.0.1:4000
sudo sysctl -w net.ipv4.conf.virbr0.route_localnet=1
```
