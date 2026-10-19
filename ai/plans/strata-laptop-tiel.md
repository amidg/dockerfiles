# Plan: laptop Strata — Tiel Coder 35B-A3B (strata-poly, UD-Q3_K_XL) on the laptop dGPU

**Date:** 2026-10-19 · **Repo:** `~/Projects/dockerfiles` · **Status:** Section A (agent work) landed
2026-10-19; Section B (the user's runbook on the laptop) is pending.

This file replaces `qwen3.6-35b-q3kxl.md`, the executed 2026-10-18 qwen3.6 plan. Its outcome is
recorded verbatim in `ai/AGENTS.md` — "Qwen3.6-35B-A3B Q3_K_XL + CPU projector" and the Tiel A/B
sections carry every number — so nothing unique is lost by the overwrite.

Run Tiel Coder 35B-A3B (`peculiar-ragdoll/Tiel-Coder-35B-A3B-GGUF-MTP`, UD-Q3_K_XL) on the
laptop's RTX 5070 8GB under **PolyStrata's `strata-poly` engine**, containerized the same way
the desktop runs Strata. Modeled on the desktop integration (`ai/Strata` submodule,
compose service, LiteLLM hop, docs, manual rollout runbook).

> **Rollout rule (same as the desktop plan):** the build agent only edits this repo; it never
> SSHes anywhere, never builds the image, never downloads weights, never runs the stack.
> Section A is agent work; Section B is the user's runbook on the laptop.

## Key distinction — two engines

The desktop's `strata` service runs the **Niko1221/Strata engine** (submodule `ai/Strata`
@ v0.1.45), which serves `qwen4exp` (Qwen3.8-Flash-Next) only. Tiel Coder runs on
**`strata-poly`**, PolyStrata's second engine (architecture `qwen35moe`, family `tiel`,
`"engine": "poly"` in setup.py), which reads the GGUF in place with a VRAM expert cache.
This plan adds a **second submodule and a second service**; the desktop `strata` service is
untouched.

**Upstream gap:** PolyStrata's `Dockerfile` compiles only the Qwen `strata` engine and
`strata-vision` — **not** `strata-poly` (its header still scopes the container path to
Qwen3.8). `docker-entrypoint.sh` accepts `FAMILY=tiel` but assumes the engine is already in
the image. The upstream-supported Linux path for `tiel` is a native `./setup.sh` that
compiles the engine on the machine. This integration therefore needs one small in-repo
Dockerfile extension (below).

## Settled decisions (2026-10-19)

- **Deployment: containerized**, mirroring the desktop — new submodule `ai/PolyStrata`
  (VecSzn/PolyStrata, pinned to a release **tag**, not main; the repo has active churn),
  compose service in `ai/llama-cpp.yml` under the `laptop` profile.
- **Container: `strata`** — the desktop's name, deliberately (user decision 2026-10-19,
  after the first commit): the container name and podman DNS name are `strata` on both
  machines, and the data dir is `/var/mnt/data/llama/strata` on both. The compose **service
  key** is `strata_laptop` only because the shared `llama-cpp.yml` cannot hold two services
  of the same name. LiteLLM reaches it at `http://strata:8080/v1`;
  `STRATA_ALLOWED_HOSTS=strata`.
- **Model: Tiel Coder 35B-A3B UD-Q3_K_XL** — the same file the llama.cpp incumbent reads.
- **Context: 131072** — matches every existing client pin (Hermes, opencode
  `limit.context`, LiteLLM `max_input_tokens`); no client rewiring.
- **Gateway name stays `tiel-coder-35b`** (desktop precedent: `qwen3.8-flash-next` names
  Swift weights). Only the `api_base` changes; no Hermes/opencode edits. The LiteLLM
  `model:` field stays `openai/tiel-coder-35b`: PolyStrata's server serves any requested
  name (`model_for`, `serve/server.py` — "Other names are still served, as before"), and
  the desktop already runs `openai/qwen3.8-flash-next` against a server whose config
  `model_name` is `swift-1.5-iq2_xs`. The engine's registry name is
  `tiel-coder-35b-a3b-ud-q3_k_xl` (`fam["name"]` + the quant); it is what `/v1/models`
  advertises, not a name any client has to use.
- **llama.cpp tiel entry stays in llama-swap as a manual fallback** (user decision). No
  LiteLLM `fallbacks:` block — this repo rejected those (swap thrashing), and the two
  backends cannot co-reside in 8GB. Switchover is a runbook step, not routing.
- **Vision: `VISION=cpu`.** Setup puts the image encoder on the CPU below 16GB VRAM; same
  decision and ~same cost profile as the desktop's `VISION=cpu`. The encoder runs in a
  separate `strata-vision` child process.
- **No arena pin.** Poly has no packed arena; its RAM need is the ~21GB expert working set
  (measured 21.8 GiB in use on the 32GB reference laptop) out of the laptop's 62GB. The
  engine still pins memory, so `ulimits.memlock: -1` carries over.
- **The separate MTP head file is NOT consumed by strata-poly** — the draft block ships
  inside the GGUF (`"draft": "own"`). The downloaded head stays on disk only because the
  llama.cpp fallback entry uses the bundled form. Do not wire it into the poly config.
- **GPU arch: 120** (RTX 5070 Laptop is Blackwell) — same `CUDA_ARCHITECTURES` build arg as
  the desktop image.
- Expected performance (PolyStrata reference laptop, RTX 4070 8GB / 32GB RAM, same file):
  **~83 t/s writes, ~1,700 t/s prompt reads** vs the llama.cpp incumbent's measured
  **40.1 t/s deep / 1442 t/s prefill**. The A/B gate below decides promotion.

## Section A — agent work (repo only) — LANDED 2026-10-19

### A1. Submodule — landed

- `ai/PolyStrata` → `https://github.com/VecSzn/PolyStrata`, pinned to **`v0.1.45-poly.1`**
  (`d0cd84dc`, 2026-10-17), `.gitmodules` entry alongside `ai/Strata`.

### A2. `ai/polystrata.Dockerfile` — landed

Reproduces the upstream image's build steps (same base image, venv, apt set, entrypoint,
healthcheck) with the poly engine build: `strata-poly` via setup.py's own
`cmake_build(..., "strata-poly", ...)` definitions, `strata-vision` built with
`-DSTRATA_VISION_CUDA=OFF` (setup.py's `cpu` arm), and `engine-poly/BUILD.json` written
with the exact fields `build_engine_poly` stamps (`source: local`, `toolkit: 13`, matching
`src` and `vision_src`), so the first start finds the engine current and skips the
compile. The Qwen `strata` engine is **not** built — the tiel family never calls it, and
skipping it halves the build.

### A3. `ai/llama-cpp.yml` — new service under the `laptop` profile — landed

```yaml
  strata_laptop:
    profiles:
      - laptop
    extends:
      file: ../base.yml
      service: base_nvidia
    build:
      context: ./PolyStrata
      dockerfile: ../polystrata.Dockerfile
      args:
        CUDA_ARCHITECTURES: 120
    image: localhost/strata-poly:0.1.45-poly.1
    container_name: strata
    restart: unless-stopped
    networks:
      - llama-swap-network
    volumes:
      - ${LLAMA_MODELS_DIR:-${HOME}/.llama/models}:/models:z
      - ${STRATA_DATA_DIR:-/var/mnt/data/llama/strata}:/data:z
    ports:
      - 8080:8080
    ulimits:
      memlock: -1
    stop_grace_period: 90s
    environment:
      - no_proxy=localhost,127.0.0.1
      - FAMILY=tiel
      - MODEL=UD-Q3_K_XL
      - CONTEXT=131072
      - VISION=cpu
      - GGUF_DIR=/models
      - STRATA_ALLOWED_HOSTS=strata
      - REINSTALL=${STRATA_REINSTALL:-0}
```

Carried-over desktop rules: `/models` mounted **writable** (`:z`, not `:z,ro` — setup
writes `.done` checksum markers); both mounts need `:z` for SELinux Enforcing; data dir
under `/var/mnt/data` on Fedora Atomic. The data dir default is **the desktop's path**
(`/var/mnt/data/llama/strata`) — separate hosts, separate disks, so the shared name never
aliases; `$STRATA_DATA_DIR` overrides on both.

Note on naming: the container is `strata`, as on the desktop; the compose **service key**
is `strata_laptop` because the shared `llama-cpp.yml` cannot hold two services of the same
name, so `podman-compose` commands take the key while `podman` commands, the podman DNS
name and the LiteLLM URL take `strata`. The engine inside remains strata-poly; the image
keeps the descriptive `localhost/strata-poly` tag. In YAML configs (no comments by repo
rule), the name is the only record.

### A4. `ai/litellm-config.laptop.yaml` — landed

- `tiel-coder-35b` entry: `api_base: http://strata:8080/v1`; `model:` field and
  everything else unchanged (`allowed_openai_params: ["reasoning_effort"]`,
  `max_input_tokens: 131072`, `max_output_tokens: 32768`).
- All other entries unchanged (`gemma-4-26b-a4b`, `gemma-4-e4b` still on
  `llama_swap_nvidia:8080`; embeddings; whisper; the desktop remote).
- The llama.cpp `tiel-coder-35b` entry stays in `llama-swap-nvidia.yaml` (manual fallback
  on `:8081/v1`, direct — not via LiteLLM, so the one `tiel-coder-35b` gateway name has
  exactly one upstream).

### A5. Docs (same-commit rule) — landed

**`ai/README.md`:** laptop section — service, port 8080, weights checklist (already on
disk: GGUF + mmproj; separate MTP head unused by poly), first-boot checks, switchover
runbook, benchmark results once measured.

**`ai/AGENTS.md`:** new section "Strata-poly on the laptop" carrying:
- the two-engine distinction (why `ai/Strata` cannot serve Tiel; what `qwen35moe` is);
- the upstream Dockerfile gap and what `ai/polystrata.Dockerfile` adds;
- co-residency rules: strata-poly holds ~7-8GB of the card while resident; **any** dGPU
  load (gemma on-demand, llama.cpp tiel fallback) requires unloading strata-poly first via
  `POST /api/models/unload` on `:8080` (poly hands VRAM back cleanly); llama-swap cannot
  call it automatically;
- the deliberate naming note: `tiel-coder-35b` names strata-poly weights; the engine's
  registry name is not a rename prompt;
- the "MTP head file unused by poly" note;
- the architecture table row and the direct-naming table updated for the new engine
  (benchmark rows to be added when measured).

### A6. Commit — landed

`feat: add strata-poly laptop service for Tiel Coder 35B (strata_laptop)`.

## Section B — manual rollout runbook (user, on the laptop) — PENDING

**B0. Prerequisites, once**
- NVIDIA driver ≥ 580 (CUDA 13); `podman`, `podman-compose`; repo cloned.
- Weights already in `$LLAMA_MODELS_DIR` (`Tiel-Coder-35B-A3B-MTP-UD-Q3_K_XL.gguf`,
  17.2GB; `mmproj-BF16.gguf`, 0.9GB — original filenames, do not rename; setup verifies
  SHA-256 against its pinned revision `bbe9e566`). Separate MTP head file: leave as-is.

**B1. Checkout**

```bash
cd ~/Projects/dockerfiles
git pull --ff-only
git submodule update --init --checkout ai/PolyStrata
```

**B2. Data dir**

```bash
mkdir -p /var/mnt/data/llama/strata
```

**B3. Build and start**

```bash
export LLAMA_MODELS_DIR=/mnt/data/llama/models        # laptop path per AGENTS.md
export STRATA_DATA_DIR=/var/mnt/data/llama/strata
podman-compose -f ai/llama-cpp.yml --profile laptop build strata_laptop   # compose takes the service key
podman-compose -f ai/llama-cpp.yml --profile laptop up -d strata_laptop
podman-compose -f ai/llama-cpp.yml --profile laptop up -d   # rest of the laptop stack
```

First start: setup pass (tokenizer dir, run config; no model download — `GGUF_DIR=/models`)
then model load. Minutes of logged silence is normal; watch `podman logs -f strata`.
If the setup pass needs to re-run after a settings change: `STRATA_REINSTALL=1` on the next
`up -d` (same mechanism as the desktop).

**B4. First-boot checks (in order, stop on first failure)**
1. `curl -s 127.0.0.1:8080/health` — up.
2. **GPU wiring:** `podman logs strata | head -50` — engine must report the RTX 5070.
   Podman CDI fallback (same as desktop): `sudo nvidia-ctk cdi generate
   --output=/etc/cdi/nvidia.yaml`, then replace `extends: base_nvidia` with
   `devices: ["nvidia.com/gpu=all"]` (+ `security_opt: label=disable` if SELinux blocks).
3. **Model id:** `curl -s 127.0.0.1:8080/v1/models | jq -r '.data[].id'` — expect
   `tiel-coder-35b-a3b-ud-q3_k_xl`. It is informational: the server answers any requested
   model name, and the LiteLLM entry keeps `openai/tiel-coder-35b`.
4. **Host-header gate:** a completion through `http://strata:8080/v1` from inside the
   LiteLLM container. If poly's server answers `403 ... not allowed` (its DNS-rebinding
   check), confirm `STRATA_ALLOWED_HOSTS=strata` survived into the container env;
   fallback is `API_KEY` (turns the check off) — decide before exposing anything.
5. **Vision:** a real 1280px image (not the harness's 1×1 PNG — twice bitten on this card).
   CPU encoder: seconds per image, not instant.
6. **Gateway:** wait 30-60s, `curl -s localhost:4000/health/liveliness`, then a real
   completion through `:4000/v1` with `model: tiel-coder-35b`.
7. **RAM:** `free -h` — expect ~22GB in use with the model resident; confirm the rest of
   the laptop stack (llama-swap containers, whisper) is not starved. Pinned memory check:
   read the engine's `/metrics` or log; `grep VmLck /proc/<pid>/status` may read 0 if poly
   pins via `cudaHostRegister` like the desktop engine (same lesson — do not trust VmLck
   alone).

**B5. A/B gate before the switch is called done**

```bash
cd ~/Projects/llm-benchmarking
export LITELLM_ENV=~/Projects/dockerfiles/ai/litellm.env
# strata-poly arm (direct :8080 — no llama-swap /api/models/unload on this backend)
./llmbench.py --endpoint http://localhost:8080/v1 --models tiel-coder-35b-a3b-ud-q3_k_xl \
  --tests all --rounds 3
# incumbent llama.cpp arm (unload strata-poly first: POST 127.0.0.1:8080/api/models/unload)
./llmbench.py --endpoint http://localhost:8081/v1 --models tiel-coder-35b \
  --tests all --rounds 3
```

Reference for the poly arm: ~83 t/s writes / ~1,700 t/s reads on the reference laptop.
Incumbent baseline: deep 40.1 / prefill 1442. Gate: tools 4/4, quality no worse than the
incumbent, vision on a real image, approval PASS (the `reasoning_effort` allowlist is
already in the LiteLLM entry). Record numbers in README + AGENTS.md in the same commit.
Note absolute values drift 20-30% with thermals — compare within the session only.

**B6. Switchover (manual fallback path, both directions)**
- poly → llama.cpp: `curl -s -X POST 127.0.0.1:8080/api/models/unload` (VRAM returned),
  then use `:8081/v1` directly (or temporarily repoint the LiteLLM entry and
  `podman restart litellm`).
- llama.cpp → poly: unload via `curl -s -X POST 127.0.0.1:8081/api/models/unload`, then any
  request to `:8080` (or restore the LiteLLM entry). poly reloads on the next request.
- gemma on-demand entries: same constraint — strata-poly must be unloaded first, or the
  8GB card OOMs. This is a documented behavior, not a bug to fix.

**B7. Rollback**
`podman-compose -f ai/llama-cpp.yml --profile laptop stop strata_laptop`, restore the
LiteLLM `api_base` line (llama.cpp tiel was never removed), `podman restart litellm`.
The submodule and image can stay; nothing else depends on them.

## Out of scope

- No downloads, no builds, no runs by the agent; all rollout is the user's runbook.
- Higher context (262144) — rejected for now: 8GB card, and it would touch every client pin.
- Renaming the gateway or client pins — none needed.
- Multi-model via poly's registry (other families) — possible later, one service per model
  decision then; the engine supports in-place model switching but the compose service pins one.
- The desktop `strata` service, Hermes/opencode configs — untouched.
- Upstream PR of the strata-poly Dockerfile support — nice-to-have, after this lands.

## Risks

- **The Dockerfile extension is adapted, not upstream-documented** — budget a debugging
  session on the first image build (BUILD.json hash bookkeeping is the fiddly part).
- **`STRATA_ALLOWED_HOSTS` is a Strata-engine env**; poly's server may not honor it. Check
  B4.4 first boot; `API_KEY` is the fallback.
- **PolyStrata churn:** pin the submodule to a tag; re-pinning is a deliberate step.
- **Co-residency:** two engines competing for 8GB is the standing failure mode; the runbook
  and AGENTS.md make the unload-first rule explicit everywhere the card is shared.
